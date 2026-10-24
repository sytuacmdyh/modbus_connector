"""Qt-free, sequential NDJSON subprocess API for the Flutter desktop client.

stdout is protocol-only; diagnostics belong on stderr. The parent sends at most
one bus request at a time, stops scheduling polls before disconnect, and owns
process lifetime. EOF/shutdown closes serial sockets and the optional demo server.
"""

from __future__ import annotations

import json
import logging
import math
import socket
import sys
import time
from typing import Any, TextIO, cast, get_args

from serial.tools import list_ports

from .backend import ModbusBackend, ModbusExceptionError
from .flutter_devices import FlutterDevices, connection_params
from .flutter_logging import FlutterLogger
from .flutter_online import FlutterOnline
from .models import RegisterKind, RtuParams, ScanProbe, TcpParams, describe_connection
from .sim_backend import SimBackend, SimTcpParams

PROTOCOL_VERSION = 1
MAX_LINE = 65536
BIT_KINDS = ("coils", "discrete_inputs")


def integer(data: dict[str, Any], key: str, low: int, high: int, default: int) -> int:
    value = data.get(key, default)
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{key} must be an integer in {low}..{high}")
    return value


def text(data: dict[str, Any], key: str, default: str = "") -> str:
    value = data.get(key, default)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} must be non-empty text")
    return value.strip()


class Bridge:
    def __init__(self) -> None:
        self.backend = ModbusBackend()
        self.logger = FlutterLogger()
        self.devices = FlutterDevices()
        self.online = FlutterOnline()
        self.demo: SimBackend | None = None
        self._demo_started = 0.0

    def close(self) -> None:
        self.online.close()
        self.devices.close()
        self.logger.close()
        self.backend.disconnect()
        if self.demo is not None:
            self.demo.stop()
            self.demo = None

    def _connect(self, data: dict[str, Any]) -> dict[str, Any]:
        transport = text(data, "transport", "rtu")
        timeout = data.get("timeout", 3.0)
        if type(timeout) not in (float, int) or not 0.1 <= timeout <= 60:
            raise ValueError("timeout must be a number in 0.1..60 seconds")
        params: TcpParams | RtuParams
        if transport == "tcp":
            params = TcpParams(text(data, "host"), integer(data, "port", 1, 65535, 502), timeout)
        elif transport == "rtu":
            parity = text(data, "parity", "N")
            if parity not in ("N", "E", "O"):
                raise ValueError("parity must be N, E or O")
            params = RtuParams(
                port=text(data, "port"),
                baudrate=integer(data, "baudrate", 50, 4000000, 9600),
                bytesize=integer(data, "bytesize", 7, 8, 8),
                parity=parity,
                stopbits=integer(data, "stopbits", 1, 2, 1),
                timeout=timeout,
            )
        elif transport in ("rtu_tcp", "rtu_udp"):
            params = connection_params(data)
        elif transport == "demo":
            # Use the same simulator/backend path as real hardware, on loopback only.
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            params = TcpParams("127.0.0.1", port, timeout)
        else:
            raise ValueError("transport must be tcp, rtu or demo")
        self.close()
        try:
            if transport == "demo":
                self.demo = SimBackend()
                self.demo.set_values("holding_registers", 0, list(range(100, 225)))
                self.demo.set_values("coils", 0, [i % 2 == 0 for i in range(2000)])
                self.demo.set_values("discrete_inputs", 0, [i % 3 == 0 for i in range(2000)])
                self.demo.start(SimTcpParams("127.0.0.1", port))
                self._demo_started = time.monotonic()
            self.backend.connect(params)
        except Exception:
            self.close()
            raise
        return {
            "description": "Demo · local TCP simulator"
            if self.demo
            else describe_connection(params)
        }

    def dispatch(self, data: dict[str, Any]) -> dict[str, Any]:
        command = text(data, "command")
        if command == "hello":
            return {"protocol": PROTOCOL_VERSION}
        if command == "ports":
            return {
                "ports": [
                    {"port": p.device, "description": p.description} for p in list_ports.comports()
                ]
            }
        if command == "connect":
            return self._connect(data)
        if command in ("disconnect", "shutdown"):
            self.close()
            return {}
        if command in ("mask_write", "read_write", "diagnostics"):
            unit = integer(data, "unit", 1, 247, 1)
            if command == "mask_write":
                address = integer(data, "address", 0, 65535, 0)
                and_mask = integer(data, "and_mask", 0, 65535, 65535)
                or_mask = integer(data, "or_mask", 0, 65535, 0)
                self.backend.mask_write_register(unit, address, and_mask, or_mask)
                return {}
            if command == "read_write":
                read_address = integer(data, "read_address", 0, 65535, 0)
                read_count = integer(data, "read_count", 1, 125, 1)
                write_address = integer(data, "write_address", 0, 65535, 0)
                values = data.get("values")
                if (
                    not isinstance(values, list)
                    or not 1 <= len(values) <= 121
                    or any(type(v) is not int or not 0 <= v <= 65535 for v in values)
                ):
                    raise ValueError("values must contain 1..121 unsigned registers")
                if read_address + read_count > 65536 or write_address + len(values) > 65536:
                    raise ValueError("Address range exceeds 65535")
                return {
                    "values": self.backend.readwrite_registers(
                        unit, read_address, read_count, write_address, values
                    )
                }
            action = text(data, "action", "loopback")
            if action == "loopback":
                return {
                    "loopback": self.backend.diag_loopback(
                        unit, integer(data, "data", 0, 65535, 0xA5A5)
                    )
                }
            if action == "counters":
                return {"counters": self.backend.diag_counters(unit)}
            if action == "clear":
                self.backend.diag_clear_counters(unit)
                return {}
            raise ValueError("Unknown diagnostic action")
        if command == "evaluate_expressions":
            from .flutter_registers import evaluate_expressions

            return evaluate_expressions(data)
        if command.startswith(("cloud_", "update_")):
            return self.online.dispatch(data)
        if command.startswith("template_"):
            from .flutter_catalog import catalog_command

            return catalog_command(data)
        if command in (
            "device_start",
            "device_stop",
            "device_status",
            "sim_configure",
            "sim_set",
            "sniffer_snapshot",
        ):
            return self.devices.dispatch(data)
        if command.startswith("logger_"):
            return self.logger.dispatch(data)
        if command in ("csv_parse", "csv_export", "encode_values", "read_rows"):
            from .flutter_registers import bounded, csv_command, encode, render, row_from_json

            if command.startswith("csv_"):
                return csv_command(data)
            if command == "encode_values":
                return {"values": encode(data)}
            raw_rows = data.get("rows")
            if not isinstance(raw_rows, list) or not 1 <= len(raw_rows) <= 512:
                raise ValueError("rows must contain 1..512 rows")
            unit = bounded(data.get("unit", 1), "unit", 1, 247)
            rows = [row_from_json(row, unit) for row in raw_rows]
            started = time.monotonic()
            results = []
            for row, options in zip(rows, raw_rows, strict=True):
                raw = self.backend.read(row.unit_id or unit, row.kind, row.address, row.count)
                results.append(render(row, raw, options))
            return {"rows": results, "elapsed_ms": (time.monotonic() - started) * 1000}
        if command in ("scan_unit", "scan_address", "device_id"):
            unit = integer(data, "unit", 1, 247, 1)
            if command == "device_id":
                return {"objects": self.backend.read_device_identification(unit)}
            if command == "scan_unit":
                raw = data.get("probes", [])
                if not isinstance(raw, list) or not 1 <= len(raw) <= 32:
                    raise ValueError("probes must contain 1..32 probe objects")
                probes = []
                for probe in raw:
                    if not isinstance(probe, dict):
                        raise ValueError("probe must be an object")
                    kind = text(probe, "kind", "holding_registers")
                    if kind not in get_args(RegisterKind):
                        raise ValueError("Unknown register area")
                    address = integer(probe, "address", 0, 65535, 0)
                    count = integer(probe, "count", 1, 2000 if kind in BIT_KINDS else 125, 1)
                    if address + count > 65536:
                        raise ValueError("Address range exceeds 65535")
                    probes.append(ScanProbe(cast(RegisterKind, kind), address, count))
                _, hits = next(self.backend.scan(probes, unit, unit, lambda: False))
                return {"unit": unit, "hits": hits}
            kind = text(data, "kind", "holding_registers")
            if kind not in get_args(RegisterKind):
                raise ValueError("Unknown register area")
            address = integer(data, "address", 0, 65535, 0)
            hits = list(
                self.backend.scan_addresses(
                    unit, cast(RegisterKind, kind), address, address, lambda: False
                )
            )
            values = hits[0][1] if hits else []
            formats = {}
            if values and kind not in BIT_KINDS:
                from .models import format_register_values

                formats = {
                    fmt: format_register_values(
                        values[:1] if fmt in ("dec", "hex", "s16") else values, fmt
                    )
                    for fmt in ("dec", "hex", "s16", "u32", "s32", "f32", "ascii")
                }
            return {"address": address, "values": values, "formats": formats}
        if command not in ("read", "write"):
            raise ValueError(f"Unknown command: {command}")
        unit = integer(data, "unit", 1, 247, 1)
        kind_text = text(data, "kind", "holding_registers")
        if kind_text not in get_args(RegisterKind):
            raise ValueError("Unknown register area")
        kind = cast(RegisterKind, kind_text)
        address = integer(data, "address", 0, 65535, 0)
        if command == "read":
            count = integer(data, "count", 1, 2000 if kind in BIT_KINDS else 125, 1)
        else:
            if kind not in ("coils", "holding_registers"):
                raise ValueError("This register area is read-only")
            values = data.get("values")
            if not isinstance(values, list) or not values:
                raise ValueError("values must be a non-empty array")
            count = len(values)
            limit = 1968 if kind == "coils" else 123
            if count > limit:
                raise ValueError(f"At most {limit} values per write")
            for value in values:
                if kind == "coils":
                    if type(value) not in (int, bool) or value not in (0, 1):
                        raise ValueError("Coil values must be boolean or 0/1")
                elif type(value) is not int or not 0 <= value <= 65535:
                    raise ValueError("Register values must be integers in 0..65535")
        if address + count > 65536:
            raise ValueError("Address range exceeds 65535")
        if not self.backend.connected:
            raise ConnectionError("Not connected; connect again")
        started = time.monotonic()
        if command == "read":
            if self.demo is not None and kind == "input_registers":
                elapsed = time.monotonic() - self._demo_started
                self.demo.set_values(
                    kind, 0, [round(1000 + 500 * math.sin(elapsed + i / 5)) for i in range(125)]
                )
            result = {"values": self.backend.read(unit, kind, address, count)}
        else:
            self.backend.write(unit, kind, address, values)
            result = {}
        return {**result, "elapsed_ms": round((time.monotonic() - started) * 1000, 2)}

    def respond(self, request: object) -> dict[str, Any]:
        request_id = request.get("id") if isinstance(request, dict) else None
        try:
            if not isinstance(request, dict):
                raise ValueError("Request must be a JSON object")
            if type(request_id) not in (int, str):
                raise ValueError("id must be an integer or string")
            result = self.dispatch(request)
            return {
                "id": request_id,
                "ok": True,
                "connected": self.backend.connected,
                "result": result,
            }
        except Exception as exc:
            error: dict[str, Any] = {"type": type(exc).__name__, "message": str(exc)}
            if isinstance(exc, ModbusExceptionError):
                error["exception_code"] = exc.exception_code
            return {
                "id": request_id,
                "ok": False,
                "connected": self.backend.connected,
                "error": error,
            }


def serve(source: TextIO, sink: TextIO) -> None:
    bridge = Bridge()
    try:
        while line := source.readline(MAX_LINE + 1):
            if len(line) > MAX_LINE:
                # Drain an oversized frame, then continue at the next NDJSON boundary.
                while not line.endswith("\n"):
                    line = source.readline(MAX_LINE + 1)
                    if not line:
                        break
                response = {
                    "id": None,
                    "ok": False,
                    "connected": bridge.backend.connected,
                    "error": {"type": "ValueError", "message": "Request too large"},
                }
                request = None
            else:
                try:
                    request = json.loads(line)
                    response = bridge.respond(request)
                except ValueError as exc:
                    request = None
                    response = {
                        "id": None,
                        "ok": False,
                        "connected": bridge.backend.connected,
                        "error": {"type": "ValueError", "message": str(exc)},
                    }
            sink.write(json.dumps(response, ensure_ascii=True, allow_nan=False) + "\n")
            sink.flush()
            if (
                isinstance(request, dict)
                and request.get("command") == "shutdown"
                and response["ok"]
            ):
                break
    finally:
        bridge.close()


def main() -> None:
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING)
    try:
        serve(sys.stdin, sys.stdout)
    except (BrokenPipeError, KeyboardInterrupt):
        pass


if __name__ == "__main__":
    main()

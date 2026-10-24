"""Qt-free lifecycle, bounded events and rules for Flutter device sessions."""

from __future__ import annotations

import math
import random
import threading
import time
from collections import deque
from typing import Any

from .flutter_registers import bounded, finite, render, row_from_json
from .gateway_backend import GatewayBackend, GatewayRtuOverTcpListenParams, GatewayTcpListenParams
from .models import (
    ConnectionParams,
    RtuOverTcpParams,
    RtuOverUdpParams,
    RtuParams,
    TcpParams,
    decode_register_values,
    encode_register_values,
    parse_expression,
)
from .sim_backend import SimBackend, SimRtuOverTcpParams, SimTcpParams
from .sniffer_backend import SnifferBackend, format_frame


def connection_params(data: object) -> ConnectionParams:
    if not isinstance(data, dict):
        raise ValueError("connection must be an object")
    timeout = finite(data.get("timeout", 3), "timeout")
    if not 0.1 <= timeout <= 60:
        raise ValueError("timeout must be 0.1..60 seconds")
    transport = data.get("transport", "rtu")
    port = data.get("port", "" if transport == "rtu" else 502)
    if transport == "rtu":
        parity = data.get("parity", "N")
        if not isinstance(port, str) or not port.strip() or parity not in ("N", "E", "O"):
            raise ValueError("Enter a serial port and N/E/O parity")
        return RtuParams(
            port,
            bounded(data.get("baudrate", 9600), "baudrate", 50, 4000000),
            bounded(data.get("bytesize", 8), "bytesize", 7, 8),
            parity,
            bounded(data.get("stopbits", 1), "stopbits", 1, 2),
            timeout,
        )
    classes = {"tcp": TcpParams, "rtu_tcp": RtuOverTcpParams, "rtu_udp": RtuOverUdpParams}
    if (
        transport not in classes
        or not isinstance(data.get("host"), str)
        or not data["host"].strip()
    ):
        raise ValueError("Choose tcp/rtu_tcp/rtu_udp and a host")
    return classes[transport](data["host"].strip(), bounded(port, "port", 1, 65535), timeout)


def listen_params(data: object, *, gateway: bool = False) -> Any:
    params = connection_params(data)
    if isinstance(params, RtuParams):
        return params
    if isinstance(params, RtuOverUdpParams):
        raise ValueError("UDP is available for targets only")
    tcp_cls = GatewayTcpListenParams if gateway else SimTcpParams
    rtu_cls = GatewayRtuOverTcpListenParams if gateway else SimRtuOverTcpParams
    return (rtu_cls if isinstance(params, RtuOverTcpParams) else tcp_cls)(params.host, params.port)


class FlutterDevices:
    def __init__(self) -> None:
        self.sim = SimBackend()
        self.sniffer = SnifferBackend()
        self.gateway = GatewayBackend()
        self.events: deque[dict[str, Any]] = deque(maxlen=2000)
        self.dropped = 0
        self.lock = threading.Lock()
        self.rows: list[dict[str, Any]] = []
        self._rules: list[Any] = []
        self._prev: dict[int, float] = {}
        self._rule_errors: dict[int, dict[str, str]] = {}
        self._stop = threading.Event()
        self._ticker: threading.Thread | None = None
        self._started = 0.0
        self.sim.on_request = lambda line: self.emit("simulator", "traffic", line=line)
        self.sim.on_master_write = lambda kind, address, values: self.emit(
            "simulator", "values", kind=kind, address=address, values=values
        )
        self.sim.on_client = lambda connected: self.emit("simulator", "client", connected=connected)
        self.sniffer.on_values = lambda unit, kind, address, values: self.emit(
            "sniffer", "values", unit=unit, kind=kind, address=address, values=values
        )
        self.sniffer.on_decoded_frame = lambda frame: self.emit(
            "sniffer", "traffic", unit=frame.unit, line=format_frame(frame)
        )
        self.sniffer.on_error = lambda line: self.emit("sniffer", "error", line=line)
        self.gateway.on_request = lambda line: self.emit("gateway", "traffic", line=line)
        self.gateway.on_error = lambda line: self.emit("gateway", "error", line=line)
        self.gateway.on_client = lambda connected: self.emit(
            "gateway", "client", connected=connected
        )

    def emit(self, mode: str, event: str, **data: Any) -> None:
        with self.lock:
            if len(self.events) == self.events.maxlen:
                self.dropped += 1
            self.events.append({"mode": mode, "event": event, **data})

    def close(self) -> None:
        self._stop.set()
        if self._ticker is not None:
            self._ticker.join(timeout=2)
            self._ticker = None
        self.sim.stop()
        self.sniffer.stop()
        self.gateway.stop()

    def _configure(self, data: dict[str, Any]) -> None:
        rows = data.get("rows")
        if not isinstance(rows, list) or len(rows) > 512:
            raise ValueError("rows must be an array of at most 512 rows")
        parsed = [row_from_json(row) for row in rows]
        funcs = {
            "rand": random.random,
            "randint": lambda a, b: float(random.randint(int(a), int(b))),
        }
        rules = []
        errors = {}
        for row, descriptor in zip(parsed, rows, strict=True):
            if row.address + row.count > 10000:
                raise ValueError("Simulator addresses must be below 10000")
            raw = descriptor.get("values")
            if raw is not None and (
                not isinstance(raw, list)
                or len(raw) != row.count
                or any(
                    type(v) not in (int, bool)
                    or not 0 <= v <= (1 if row.kind in ("coils", "discrete_inputs") else 65535)
                    for v in raw
                )
            ):
                raise ValueError("Invalid simulator raw values")
            rule = descriptor.get("rule_text", "")
            try:
                rules.append(
                    parse_expression(rule, extra_functions=funcs, extra_names=("t", "prev"))
                    if rule
                    else None
                )
            except ValueError as exc:
                rules.append(None)
                errors[len(rules) - 1] = {"code": "invalid_rule", "detail": str(exc)}
        with self.lock:
            self.rows = rows
            self._rules = rules
            self._rule_errors = errors
            self._prev.clear()
            for row, descriptor in zip(parsed, rows, strict=True):
                if "values" in descriptor:
                    self.sim.set_values(row.kind, row.address, descriptor["values"])

    def _tick(self, interval: float) -> None:
        while not self._stop.wait(interval):
            with self.lock:
                values = {}
                for descriptor in self.rows:
                    row = row_from_json(descriptor)
                    if row.format in ("hex", "ascii", "ascii1"):
                        continue
                    raw = self.sim.get_values(row.kind, row.address, row.count)
                    decoded = (
                        [int(raw[0])]
                        if row.kind in ("coils", "discrete_inputs")
                        else decode_register_values(raw, row.format, row.order or "ABCD")
                    )
                    values[row.name] = decoded[0]
                for i, (descriptor, expr) in enumerate(zip(self.rows, self._rules, strict=True)):
                    if expr is None:
                        continue
                    row = row_from_json(descriptor)
                    try:
                        value = expr.evaluate(
                            values,
                            names={
                                "t": time.monotonic() - self._started,
                                "prev": self._prev.get(i, values.get(row.name, 0)),
                            },
                        )
                        if not math.isfinite(value):
                            self._rule_errors[i] = {"code": "nonfinite_rule", "detail": ""}
                            continue
                        raw = (
                            [bool(round(value))] * row.count
                            if row.kind in ("coils", "discrete_inputs")
                            else encode_register_values(value, row.format, row.order or "ABCD")
                        )
                        self.sim.set_values(row.kind, row.address, (raw * row.count)[: row.count])
                        self._prev[i] = value
                        self._rule_errors.pop(i, None)
                    except KeyError as exc:
                        self._rule_errors[i] = {"code": "missing_reference", "detail": str(exc)}
                    except (ValueError, ArithmeticError) as exc:
                        self._rule_errors[i] = {
                            "code": "rule_evaluation_failed",
                            "detail": str(exc),
                        }

    def dispatch(self, data: dict[str, Any]) -> dict[str, Any]:
        command = data["command"]
        if command == "sim_configure":
            self._configure(data)
            return {"rule_errors": {str(i): e for i, e in self._rule_errors.items()}}
        if command == "device_start":
            mode = data.get("mode")
            # Validate everything before replacing a running service.
            if mode == "simulator":
                params = listen_params(data.get("listen"))
                unit = data.get("unit")
                if unit is not None:
                    bounded(unit, "unit", 1, 247)
                interval = bounded(data.get("tick_ms", 1000), "tick_ms", 100, 10000)
                self.close()
                self.sim.start(params, unit)
                self._started = time.monotonic()
                self._stop.clear()
                self._ticker = threading.Thread(
                    target=self._tick, args=(interval / 1000,), daemon=True
                )
                self._ticker.start()
            elif mode == "sniffer":
                params = connection_params(data.get("listen"))
                if not isinstance(params, RtuParams):
                    raise ValueError("Sniffer requires a serial RTU adapter")
                self.close()
                self.sniffer.start(params)
            elif mode == "gateway":
                params = listen_params(data.get("listen"), gateway=True)
                target = connection_params(data.get("target"))
                units = data.get("units")
                if units is not None:
                    if not isinstance(units, list) or not units:
                        raise ValueError("units must be null or a nonempty array")
                    units = {bounded(u, "unit", 1, 247) for u in units}
                self.close()
                self.gateway.start(params, target, units)
            else:
                raise ValueError("Unknown device mode")
            return {"running": True}
        if command == "device_stop":
            self.close()
            return {"running": False}
        if command == "sim_set":
            row = row_from_json(data.get("row"))
            values = data.get("values")
            if (
                not isinstance(values, list)
                or len(values) != row.count
                or any(
                    type(v) not in (int, bool)
                    or not 0 <= v <= (1 if row.kind in ("coils", "discrete_inputs") else 65535)
                    for v in values
                )
            ):
                raise ValueError("Invalid simulator values")
            self.sim.set_values(row.kind, row.address, values)
            return {}
        if command == "sniffer_snapshot":
            unit = bounded(data.get("unit", 1), "unit", 1, 247)
            return {"unit": unit, "areas": self.sniffer.snapshot(unit)}
        if command == "device_status":
            with self.lock:
                events = list(self.events)
                self.events.clear()
                dropped = self.dropped
                self.dropped = 0
                rule_errors = {str(i): dict(e) for i, e in self._rule_errors.items()}
                results = [
                    render(
                        row_from_json(d),
                        self.sim.get_values(
                            row_from_json(d).kind, row_from_json(d).address, row_from_json(d).count
                        ),
                        d,
                    )
                    for d in self.rows
                ]
            return {
                "simulator": self.sim.running,
                "sniffer": self.sniffer.running,
                "gateway": self.gateway.running,
                "events": events,
                "dropped": dropped,
                "rows": results,
                "rule_errors": rule_errors,
                "units": self.sniffer.units(),
            }
        raise ValueError("Unknown device command")

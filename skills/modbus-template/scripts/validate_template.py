"""Validate generated public templates offline, using only Python's standard library."""

import argparse
import json
import math
from pathlib import Path
from typing import Any

KINDS = {"coils", "discrete_inputs", "holding_registers", "input_registers"}
WIDTHS = {"u16": 1, "hex": 1, "s16": 1, "u32": 2, "s32": 2, "f32": 2,
          "u64": 4, "s64": 4, "f64": 4, "ascii": 1, "ascii1": 1}
ORDERS = {"", "ABCD", "CDAB", "BADC", "DCBA"}


def integer(value: Any, low: int, high: int) -> bool:
    return type(value) is int and low <= value <= high


def number(value: Any) -> bool:
    try:
        return type(value) in (int, float) and math.isfinite(value)
    except OverflowError:
        return False


def canonical_format(value: Any) -> Any:
    """Normalize the pre-u16 unsigned-16 spelling used by old templates."""
    if not isinstance(value, str):
        return value
    value = value.lower()
    return "u16" if value == "dec" else value


def validate(data: Any) -> list[str]:
    errors: list[str] = []

    def check(ok: bool, message: str) -> None:
        if not ok:
            errors.append(message)

    if not isinstance(data, dict):
        return ["template must be an object"]
    check(isinstance(data.get("name"), str) and bool(data["name"].strip()), "name is required")
    conn = data.get("connection")
    if not isinstance(conn, dict):
        errors.append("connection must be an object")
    else:
        if "type" in conn:
            check(conn["type"] in ("RTU", "TCP", "RTU over TCP", "RTU over UDP"),
                  "connection.type is invalid")
        if "unit" in conn:
            check(integer(conn["unit"], 1, 247), "connection.unit must be 1..247")
        if "tcp_port" in conn:
            check(integer(conn["tcp_port"], 1, 65535), "connection.tcp_port must be 1..65535")
        if "timeout" in conn:
            check(number(conn["timeout"]) and conn["timeout"] > 0,
                  "connection.timeout must be finite and positive")
        for key in ("rtu_port", "tcp_host"):
            if key in conn:
                check(isinstance(conn[key], str), f"connection.{key} must be a string")
        if "rtu_baud" in conn:
            baud = conn["rtu_baud"]
            check(isinstance(baud, str) and baud.isascii() and baud.isdecimal()
                  and int(baud) > 0, "connection.rtu_baud must be a positive decimal string")
        for key, choices in (("rtu_bytesize", ("5", "6", "7", "8")),
                             ("rtu_parity", ("N", "E", "O")), ("rtu_stopbits", ("1", "2"))):
            if key in conn:
                check(conn[key] in choices, f"connection.{key} is invalid")
    rows = data.get("registers")
    if not isinstance(rows, list) or not rows:
        return [*errors, "registers must be a non-empty array"]
    seen: set[tuple[Any, str, int]] = set()
    for index, row in enumerate(rows):
        label = f"registers[{index}]"
        if not isinstance(row, dict):
            errors.append(f"{label} must be an object")
            continue
        check(isinstance(row.get("name"), str) and bool(row["name"].strip()),
              f"{label}.name is required")
        kind, fmt = row.get("kind", "holding_registers"), canonical_format(
            row.get("format", "u16")
        )
        if not isinstance(kind, str) or kind not in KINDS:
            errors.append(f"{label}.kind is invalid")
            continue
        if not isinstance(fmt, str) or fmt not in WIDTHS:
            errors.append(f"{label}.format is invalid")
            continue
        bits = kind in ("coils", "discrete_inputs")
        address, count = row.get("address"), row.get("count")
        valid_span = integer(address, 0, 65535) and integer(count, 1, 2000 if bits else 125)
        check(valid_span, f"{label}: invalid address/count")
        if valid_span:
            check(address + count <= 65536, f"{label}: span exceeds address 65535")
            check(count % WIDTHS[fmt] == 0, f"{label}: count is not a multiple of format width")
        check(not bits or fmt == "u16", f"{label}: use u16 for bit areas")
        order = row.get("order", "")
        check(isinstance(order, str) and order in ORDERS, f"{label}.order is invalid")
        unit = row.get("unit_id")
        valid_unit = unit is None or unit == "" or integer(unit, 1, 247)
        check(valid_unit, f"{label}.unit_id must be an integer 1..247 or omitted")
        if valid_span and valid_unit:
            effective_unit = unit if unit not in (None, "") else (
                conn.get("unit", 1) if isinstance(conn, dict) else 1
            )
            if integer(effective_unit, 1, 247):
                key = (effective_unit, kind, address)
                check(key not in seen, f"{label}: duplicate unit/kind/address")
                seen.add(key)
        for field in ("scale", "offset"):
            if field in row:
                check(number(row[field]), f"{label}.{field} must be finite")
        if "unit" in row:
            check(isinstance(row["unit"], str), f"{label}.unit must be a display string")
        for field in ("bitmask", "poll_enabled", "trend_enabled"):
            if field in row:
                check(type(row[field]) is bool, f"{label}.{field} must be boolean")
        names = row.get("value_names", {})
        check(isinstance(names, dict), f"{label}.value_names must be an object")
        if isinstance(names, dict):
            for key, value in names.items():
                try:
                    parsed = int(key)
                    valid_key = str(parsed) == key
                except (ValueError, TypeError):
                    valid_key = False
                    parsed = -1
                check(valid_key and isinstance(value, str), f"{label}: invalid enum entry {key!r}")
                if row.get("bitmask") is True:
                    check(0 <= parsed <= 15, f"{label}: bit index must be 0..15")
        if names or row.get("bitmask") is True:
            check(count == 1 and fmt in ("u16", "s16", "hex"),
                  f"{label}: annotations require a single u16/s16/hex value")
    return errors


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", type=Path, nargs="+")
    failed = False
    for path in parser.parse_args().files:
        try:
            data = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
            errors = validate(data)
        except (OSError, ValueError) as exc:
            errors = [str(exc)]
        failed |= bool(errors)
        print(f"{path}: " + ("FAIL\n  " + "\n  ".join(errors) if errors else "OK"))
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())

"""Qt-free register tools shared by the Flutter bridge commands."""

from __future__ import annotations

import math
from dataclasses import asdict
from typing import Any, cast, get_args

from .models import (
    ByteOrder,
    DisplayFormat,
    RegisterKind,
    RegisterRow,
    RowDisplaySettings,
    alarm_rule_to_json,
    alarm_rules_from_json,
    csv_header,
    decode_register_values,
    encode_ascii_values,
    encode_register_values,
    evaluate_alarm,
    format_bitmask_value,
    format_named_value,
    format_register_values,
    format_scaled_values,
    guess_column_mapping,
    parse_formatted_values,
    register_width,
    rows_from_csv,
    rows_to_csv,
    value_names_from_json,
)


def bounded(value: object, name: str, low: int, high: int) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{name} must be an integer in {low}..{high}")
    return value


def finite(value: object, name: str) -> float:
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError(f"{name} must be finite")
    return float(value)


def row_from_json(data: object, unit: int = 1) -> RegisterRow:
    if not isinstance(data, dict):
        raise ValueError("row must be an object")
    kind = data.get("kind", "holding_registers")
    fmt = data.get("format", "dec")
    order = data.get("order") or "ABCD"
    if kind not in get_args(RegisterKind) or fmt not in get_args(DisplayFormat):
        raise ValueError("Unknown register area or display format")
    if order not in get_args(ByteOrder):
        raise ValueError("Unknown byte order")
    bit = kind in ("coils", "discrete_inputs")
    address = bounded(data.get("address", 0), "address", 0, 65535)
    count = bounded(data.get("count", 1), "count", 1, 2000 if bit else 125)
    if address + count > 65536 or (not bit and count < register_width(fmt)):
        raise ValueError("Invalid row range or count smaller than display width")
    unit_id = bounded(unit if data.get("unit_id") is None else data["unit_id"], "unit_id", 1, 247)
    poll_ms = data.get("poll_ms")
    if poll_ms is not None:
        bounded(poll_ms, "poll_ms", 100, 86400000)
    return RegisterRow(
        name=str(data.get("name", "")),
        kind=cast(RegisterKind, kind),
        address=address,
        count=count,
        format=cast(DisplayFormat, fmt),
        order=cast(ByteOrder, order),
        scale=finite(data.get("scale", 1), "scale"),
        offset=finite(data.get("offset", 0), "offset"),
        unit=str(data.get("unit", "")),
        unit_id=unit_id,
        poll_ms=poll_ms,
    )


def planned_groups(rows: list[RegisterRow]) -> list[list[int]]:
    from .models import ReadSpec, plan_grouped_reads

    specs = [
        ReadSpec(i, r.unit_id, r.kind, r.address, r.count)
        for i, r in enumerate(rows)
        if r.poll_ms is None
    ]
    return [[member.token for member in plan.members] for plan in plan_grouped_reads(specs)] + [
        [i] for i, row in enumerate(rows) if row.poll_ms is not None
    ]


def render(row: RegisterRow, raw: list[int | bool], options: dict[str, Any]) -> dict[str, Any]:
    numeric: list[int | float] = []
    if row.kind in ("coils", "discrete_inputs"):
        numeric = [int(v) for v in raw]
        display = ", ".join(str(int(v)) for v in raw)
    elif row.format in ("hex", "ascii", "ascii1"):
        display = format_register_values(raw, row.format, row.order or "ABCD")
    else:
        numeric = decode_register_values(raw, row.format, row.order or "ABCD")
        display = format_scaled_values(numeric, row.scale, row.offset, row.unit)
    primary = numeric[0] * row.scale + row.offset if numeric else None
    names = value_names_from_json(options.get("value_names"))
    if len(raw) == 1 and options.get("bitmask"):
        display = format_bitmask_value(int(raw[0]), names)
    elif len(raw) == 1 and names:
        display = format_named_value(names, raw[0]) or display
    alarm = (
        evaluate_alarm(primary, alarm_rules_from_json(options.get("alarms")))
        if (primary is not None and math.isfinite(primary))
        else None
    )
    return {
        "values": raw,
        "display": display,
        "numeric": primary if primary is not None and math.isfinite(primary) else None,
        "alarm": alarm_rule_to_json(alarm) if alarm else None,
    }


def encode(data: dict[str, Any]) -> list[int | bool]:
    row = row_from_json(data.get("row"))
    content = data.get("text")
    if not isinstance(content, str):
        raise ValueError("text must be a string")
    if row.kind in ("coils", "discrete_inputs"):
        tokens = content.replace(",", " ").split()
        if len(tokens) != row.count or any(
            v.lower() not in ("0", "1", "true", "false") for v in tokens
        ):
            raise ValueError("Enter exactly count boolean values (0/1)")
        return [v.lower() in ("1", "true") for v in tokens]
    if row.format in ("ascii", "ascii1"):
        if row.format == "ascii1":
            return [
                ord(c) if ord(c) < 128 else 63 for c in content[: row.count].ljust(row.count, "\0")
            ]
        return encode_ascii_values(content, row.count)
    if row.format == "hex":
        return parse_formatted_values(content, row.format, row.count)
    if row.scale == 0:
        raise ValueError("Cannot invert zero scale")
    values: list[int] = []
    for token in content.replace(",", " ").split():
        value = finite(float(token), "value")
        values.extend(
            encode_register_values(
                (value - row.offset) / row.scale, row.format, row.order or "ABCD"
            )
        )
    if len(values) != row.count:
        raise ValueError(f"Enter {row.count // register_width(row.format)} values")
    return values


def csv_command(data: dict[str, Any]) -> dict[str, Any]:
    if data["command"] == "csv_parse":
        content = data.get("text", "")
        if not isinstance(content, str):
            raise ValueError("text must be a string")
        header = csv_header(content)
        if data.get("preview"):
            return {"header": header, "mapping": guess_column_mapping(header)}
        mapping = data.get("mapping")
        if mapping is not None and (
            not isinstance(mapping, dict)
            or any(not isinstance(k, str) or not isinstance(v, str) for k, v in mapping.items())
        ):
            raise ValueError("mapping must map source column names to fields")
        result = []
        for row, display in rows_from_csv(content, mapping):
            record = {**asdict(row), **asdict(display)}
            row_from_json(record)
            result.append(record)
        if len(result) > 512:
            raise ValueError("At most 512 rows")
        return {"rows": result}
    raw_rows = data.get("rows", [])
    if not isinstance(raw_rows, list) or len(raw_rows) > 512:
        raise ValueError("rows must be an array of at most 512 rows")
    rows = [row_from_json(row) for row in raw_rows]
    displays = [
        RowDisplaySettings(scale=row.scale, offset=row.offset, unit=row.unit, order=row.order)
        for row in rows
    ]
    columns = data.get("columns")
    from .models import CSV_COLUMNS

    if columns is not None and (
        not isinstance(columns, list) or not columns or any(c not in CSV_COLUMNS for c in columns)
    ):
        raise ValueError("Unknown CSV columns")
    return {"text": rows_to_csv(rows, displays, columns)}


def evaluate_expressions(data: dict[str, Any]) -> dict[str, Any]:
    from .models import parse_expression

    rows = data.get("expressions")
    values = data.get("values")
    if not isinstance(rows, list) or len(rows) > 512 or not isinstance(values, dict):
        raise ValueError("expressions must be an array; values must be an object")
    available = {
        k: float(v)
        for k, v in values.items()
        if isinstance(k, str) and type(v) in (int, float) and math.isfinite(v)
    }
    results = []
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("text"), str):
            raise ValueError("Expression requires text")
        try:
            value = parse_expression(row["text"]).evaluate(available)
            if not math.isfinite(value):
                raise ValueError("Expression result is not finite")
            alarm = evaluate_alarm(value, alarm_rules_from_json(row.get("alarms")))
            results.append(
                {
                    "numeric": value,
                    "display": f"{value:.6g}",
                    "error": None,
                    "alarm": alarm_rule_to_json(alarm) if alarm else None,
                }
            )
        except (ValueError, KeyError, ArithmeticError) as exc:
            results.append({"numeric": None, "display": "—", "error": str(exc), "alarm": None})
    return {"rows": results}

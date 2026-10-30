"""Regenerate native Dart compatibility fixtures using the Python reference.

Development only; the desktop neither ships nor executes this script.
Run from the repository root after installing the headless Python package.
"""
import json
from pathlib import Path

from modbus_connector.flutter_bridge import Bridge
from modbus_connector.models import register_width

bridge = Bridge()
cases = []


def record(request):
    reply = bridge.respond({"id": 1, **request})
    if not reply["ok"]:
        raise RuntimeError(reply)
    cases.append({"request": request, "result": reply["result"]})


try:
    for fmt in ["dec", "s16", "u32", "s32", "f32", "u64", "s64", "f64", "hex", "ascii", "ascii1"]:
        for order in ["ABCD", "BADC", "CDAB", "DCBA"]:
            for values in [[0]*4, [65535]*4, [1, 2, 3, 4], [16968, 0, 0, 0]]:
                record({"command": "render_rows", "rows": [{
                    "format": fmt, "order": order, "count": 4, "values": values,
                    "scale": 0.1, "offset": -3, "unit": "℃",
                }]})
    for fmt in ["dec", "s16", "u32", "s32", "f32", "u64", "s64", "f64"]:
        for order in ["ABCD", "BADC", "CDAB", "DCBA"]:
            for value in ["-2.5", "0", "3.5", "1234.125"]:
                record({"command": "encode_values", "row": {
                    "format": fmt, "order": order, "count": register_width(fmt),
                }, "text": value})
    for text in ["1+2*3", "-2**2", "2**-2", "7//-2", "7%-2", "round(2.5)",
                 "round(3.5)", "clamp([温度],0,10)", "log(8,2)", "[温度]*0.1+2",
                 "min(4,2,8)", "sin(pi/2)", "sqrt(-1)"]:
        record({"command": "evaluate_expressions", "expressions": [{"text": text}],
                "values": {"温度": 123}})
    for value in [0, 1, 5, 65535]:
        for fmt in ["dec", "s16", "hex"]:
            for bitmask in [False, True]:
                record({"command": "render_rows", "rows": [{
                    "format": fmt, "values": [value], "bitmask": bitmask,
                    "value_names": {"0": "Off", "1": "Run", "2": "Alarm"},
                    "alarms": [{"condition": "ge", "value": 1}],
                }]})
    for condition in ["gt", "ge", "lt", "le", "eq", "ne", "in_range", "outside_range"]:
        rule = {"condition": condition, "value": 2, "color": "yellow", "sound": True}
        if condition.endswith("range"):
            rule["value2"] = -1
        record({"command": "evaluate_expressions", "expressions": [
            {"text": "1", "alarms": [rule]},
        ], "values": {}})
    for text in ["name,type,address\n温度,holding_registers,0x10\n",
                 "name,kind,address,count,format,unit_id,poll_ms\nSensor,input_registers,4,2,f32,7,100\n"]:
        record({"command": "csv_parse", "text": text})
    destination = Path(__file__).resolve().parents[1] / "test_backend/fixtures/python_backend.json"
    destination.write_text(json.dumps(cases, ensure_ascii=False, allow_nan=False, indent=2),
                           encoding="utf-8")
    print(f"Wrote {len(cases)} reference cases")
finally:
    bridge.close()

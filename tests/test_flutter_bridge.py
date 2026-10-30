"""The desktop bridge exercises the existing backend without importing Qt."""

import io
import json
import os
import subprocess
import sys
from collections.abc import Iterator

import pytest

from modbus_connector.flutter_bridge import MAX_LINE, Bridge, serve
from modbus_connector.models import RtuParams


@pytest.fixture()
def bridge() -> Iterator[Bridge]:
    instance = Bridge()
    yield instance
    instance.close()


def request(bridge: Bridge, command: str, **params: object) -> dict:
    return bridge.respond({"id": 7, "command": command, **params})


def test_qt_workspace_conversion_preserves_raw_semantics_and_device_parameters(bridge):
    original = {
        "active_tab": 1,
        "cloud_password": "must not migrate",
        "tabs": [
            {"mode": "master", "connection": {"type": "TCP", "unit": 7},
             "registers_options": {"order": "CDAB", "group_reads": True},
             "registers": [{"name": "温度", "kind": "holding_registers", "address": 8,
                            "count": 2, "format": "f32", "unit_id": "", "poll_ms": "",
                            "order": "", "scale": 0.1}],
             "expressions": [{"name": "double", "expr": "[温度]*2"}]},
            {"mode": "slave", "sim": {"server": {"type": "TCP", "host": "127.0.0.1",
                                                    "port": 1555, "unit": "any"},
                                      "tick_ms": 200, "rows": []}},
            {"mode": "gateway", "gateway": {"listen": {"type": "RTU", "rtu_port": "COM9"},
                                                "target": {"type": "TCP", "tcp_port": 1502},
                                                "units": "7,8"}},
        ],
    }
    reply = request(bridge, "template_convert_workspace", workspace=original)
    assert reply["ok"], reply
    converted = reply["result"]
    assert converted["active_tab"] == 1
    assert "cloud_password" not in converted
    master, simulator, gateway = converted["tabs"]
    assert master["registers"][0]["unit_id"] is None
    assert master["registers"][0]["poll_ms"] is None
    assert master["registers"][0]["order"] == "CDAB"
    assert master["expressions"][0]["text"] == "[温度]*2"
    assert master["map_grouped"] is True
    assert simulator["mode"] == "simulator"
    assert simulator["device_config"]["listen"]["port"] == 1555
    assert simulator["device_config"]["units_text"] == ""
    assert gateway["device_config"]["listen"]["port"] == "COM9"
    assert gateway["device_config"]["target"]["port"] == 1502
    assert not request(bridge, "template_convert_workspace", workspace={"tabs": []})["ok"]


def test_all_public_template_rows_are_usable_after_flutter_conversion(cloud_template_cache):
    del cloud_template_cache
    from modbus_connector.flutter_catalog import flutter_state, public_catalog, public_template
    from modbus_connector.flutter_registers import row_from_json

    catalog = public_catalog()
    assert catalog
    for entry in catalog:
        source = public_template(entry.resource)
        converted = flutter_state(source)
        assert len(converted["registers"]) == len(source.get("registers", []))
        for row in converted["registers"]:
            assert {
                "name", "kind", "address", "count", "format", "scale", "offset", "unit",
            } <= row.keys()
            assert row["order"] in ("ABCD", "CDAB", "BADC", "DCBA")
            row_from_json(row, converted["unit"])


def test_flutter_catalog_normalizes_legacy_dec_rows() -> None:
    from modbus_connector.flutter_catalog import flutter_state

    converted = flutter_state({
        "connection": {"type": "RTU", "unit": 1},
        "registers": [{"name": "Status", "address": 4, "count": 1, "format": "dec"}],
    })
    assert converted["registers"][0]["format"] == "u16"


def test_master_traffic_contains_real_bytes_on_success_and_exception(bridge):
    assert request(bridge, "connect", transport="demo", timeout=0.1)["ok"]
    read = request(bridge, "read", unit=1, kind="holding_registers", address=0, count=2)
    assert read["ok"]
    assert {frame["direction"] for frame in read["traffic"]} == {"tx", "rx"}
    assert all(bytes.fromhex(frame["hex"]) for frame in read["traffic"])
    assert read["statistics"]["operations"] == 1
    assert read["statistics"]["tx_bytes"] > 0
    failed = request(bridge, "read", unit=1, kind="holding_registers", address=65535, count=1)
    assert not failed["ok"]
    assert failed["traffic"]
    assert failed["statistics"]["errors"] == 1
    assert failed["statistics"]["operations"] == 2
    assert request(bridge, "hello")["traffic"] == []


def test_real_tcp_read_write_reconnect(bridge: Bridge, modbus_server: int) -> None:
    reply = request(bridge, "connect", transport="tcp", host="127.0.0.1", port=modbus_server)
    assert reply["id"] == 7 and reply["ok"] and reply["connected"]
    reply = request(bridge, "read", count=3)
    assert reply["result"]["values"] == [100, 101, 102]
    assert reply["result"]["elapsed_ms"] >= 0
    assert request(bridge, "write", address=1, values=[54321])["ok"]
    assert request(bridge, "read", address=1)["result"]["values"] == [54321]
    assert request(bridge, "write", kind="coils", values=[0, 1])["ok"]
    assert request(bridge, "read", kind="coils", count=2)["result"]["values"] == [False, True]
    assert request(bridge, "read", kind="discrete_inputs")["result"]["values"] == [False]
    assert request(bridge, "read", kind="input_registers")["result"]["values"] == [7]
    exception = request(bridge, "read", address=60000)
    assert not exception["ok"] and exception["error"]["exception_code"] == 2
    assert request(bridge, "disconnect")["connected"] is False
    assert not request(bridge, "read")["ok"]
    assert request(bridge, "connect", transport="tcp", host="127.0.0.1", port=modbus_server)["ok"]
    assert request(bridge, "read")["ok"]


@pytest.mark.parametrize(
    "params",
    [
        {"command": "read", "unit": 0},
        {"command": "read", "unit": 248},
        {"command": "read", "count": 126},
        {"command": "read", "kind": "coils", "count": 2001},
        {"command": "read", "address": 65535, "count": 2},
        {"command": "read", "address": True},
        {"command": "read", "count": 1.5},
        {"command": "write", "values": [65536]},
        {"command": "write", "values": [-1]},
        {"command": "write", "values": [True]},
        {"command": "write", "values": []},
        {"command": "write", "values": [1] * 124},
        {"command": "write", "kind": "coils", "values": [2]},
        {"command": "write", "kind": "input_registers", "values": [1]},
        {"command": "connect", "transport": "rtu", "port": "COM1", "parity": "X"},
        {"command": "connect", "transport": "tcp", "host": "localhost", "timeout": float("nan")},
        {"command": "connect", "transport": "tcp", "host": "localhost", "port": 0},
        {"command": "nope"},
    ],
)
def test_invalid_request_never_reaches_io(bridge: Bridge, params: dict, monkeypatch) -> None:
    def unexpected(*args, **kwargs):
        pytest.fail("Invalid request reached the bus")

    monkeypatch.setattr(bridge.backend, "connect", unexpected)
    monkeypatch.setattr(bridge.backend, "read", unexpected)
    monkeypatch.setattr(bridge.backend, "write", unexpected)
    result = bridge.respond({"id": "bad", **params})
    assert result["id"] == "bad" and not result["ok"]
    assert result["error"]["type"] == "ValueError"


def test_rtu_fields_passed_to_existing_backend(bridge: Bridge, monkeypatch) -> None:
    captured = []
    monkeypatch.setattr(bridge.backend, "connect", captured.append)
    assert request(
        bridge,
        "connect",
        transport="rtu",
        port="COM17",
        baudrate=19200,
        bytesize=7,
        parity="E",
        stopbits=2,
        timeout=0.2,
    )["ok"]
    assert captured == [RtuParams("COM17", 19200, 7, "E", 2, 0.2)]


def test_frames_errors_and_shutdown() -> None:
    source = io.StringIO(
        'broken\n[]\n{"command":"hello"}\n' + "x" * (MAX_LINE + 3) + "\n"
        '{"id":1,"command":"hello"}\n'
        '{"id":2,"command":"shutdown"}\n'
        '{"id":3,"command":"hello"}\n'
    )
    sink = io.StringIO()
    serve(source, sink)
    replies = [json.loads(line) for line in sink.getvalue().splitlines()]
    assert len(replies) == 6
    assert all(not item["ok"] for item in replies[:4])
    assert replies[4]["result"]["protocol"] == 1
    assert replies[5]["id"] == 2 and replies[5]["ok"]


def test_demo_map_reads_animate_and_preserve_writes(bridge: Bridge) -> None:
    assert request(bridge, "connect", transport="demo")["ok"]
    rows = [
        {"name": "Signal", "kind": "input_registers", "address": 0, "count": 1},
        {"name": "Setpoint", "kind": "holding_registers", "address": 0, "count": 1},
    ]
    first = request(bridge, "read_rows", rows=rows, unit=1)["result"]["rows"]
    assert 500 <= first[0]["values"][0] <= 1500
    assert request(bridge, "write", address=0, values=[321])["ok"]
    bridge._demo_started -= 2
    second = request(bridge, "read_rows", rows=rows, unit=1, grouped=True)["result"]["rows"]
    assert second[0]["values"] != first[0]["values"]
    assert second[1]["values"] == [321]


def test_demo_uses_real_backend_and_cleans_up(bridge: Bridge) -> None:
    assert request(bridge, "connect", transport="demo")["connected"]
    demo = bridge.demo
    assert demo is not None and demo.running
    assert request(bridge, "read", count=2)["result"]["values"] == [100, 101]
    assert request(bridge, "write", values=[4321])["ok"]
    assert request(bridge, "read")["result"]["values"] == [4321]
    assert 500 <= request(bridge, "read", kind="input_registers")["result"]["values"][0] <= 1500
    request(bridge, "disconnect")
    assert not demo.running and bridge.demo is None


@pytest.mark.parametrize("shutdown", [False, True])
def test_subprocess_protocol_eof_and_no_qt(shutdown: bool) -> None:
    commands = [
        {"id": 1, "command": "connect", "transport": "demo"},
        {"id": 2, "command": "read", "count": 2},
    ]
    if shutdown:
        commands.append({"id": 3, "command": "shutdown"})
    completed = subprocess.run(
        [sys.executable, "-u", "-m", "modbus_connector.flutter_bridge"],
        input="".join(json.dumps(command) + "\n" for command in commands),
        capture_output=True,
        text=True,
        timeout=20,
        env={**os.environ, "QT_QPA_PLATFORM": "invalid"},
    )
    assert completed.returncode == 0, completed.stderr
    replies = [json.loads(line) for line in completed.stdout.splitlines()]
    assert len(replies) == len(commands) and all(reply["ok"] for reply in replies)
    assert replies[1]["result"]["values"] == [100, 101]
    probe = subprocess.run(
        [
            sys.executable,
            "-c",
            "import sys; "
            "import modbus_connector.flutter_bridge; "
            "assert not any('PySide' in m for m in sys.modules)",
        ],
        timeout=10,
    )
    assert probe.returncode == 0


@pytest.mark.parametrize("system_encoding", ["gbk", "cp1252"])
def test_subprocess_uses_utf8_for_unescaped_chinese_template_paths(system_encoding, tmp_path):
    resource = "测试厂家/中文设备.json"
    template = {
        "name": "中文设备", "connection": {"type": "RTU", "unit": 1},
        "registers": [{"name": "温度", "kind": "holding_registers", "address": 0,
                       "count": 1, "format": "s16"}],
    }
    (tmp_path / "cloud_templates.json").write_text(
        json.dumps({resource: template}, ensure_ascii=False), encoding="utf-8",
    )
    command = {"id": 1, "command": "template_load", "resource": resource}
    completed = subprocess.run(
        [sys.executable, "-u", "-m", "modbus_connector.flutter_bridge"],
        input=(json.dumps(command, ensure_ascii=False) + "\n").encode("utf-8"),
        capture_output=True, timeout=20,
        env={**os.environ, "PYTHONIOENCODING": system_encoding,
             "MODBUS_FLUTTER_HOME": str(tmp_path)},
    )
    assert completed.returncode == 0, completed.stderr
    reply = json.loads(completed.stdout)
    assert reply["ok"], reply
    assert reply["result"]["state"]["name"] == template["name"]
    assert reply["result"]["state"]["registers"]


def test_scanner_real_backend(bridge: Bridge, modbus_server: int) -> None:
    assert request(bridge, "connect", transport="tcp", host="127.0.0.1", port=modbus_server)["ok"]
    result = request(
        bridge,
        "scan_unit",
        unit=1,
        probes=[
            {"kind": "holding_registers", "address": 0, "count": 1},
            {"kind": "holding_registers", "address": 60000, "count": 1},
        ],
    )
    assert result["result"]["hits"] == [0]
    assert request(bridge, "scan_address", address=0)["result"]["values"] == [100, 101]
    assert request(bridge, "scan_address", address=60000)["result"]["values"] == []
    assert not request(bridge, "scan_unit", probes=[{"address": 65535, "count": 2}])["ok"]
    assert not request(bridge, "scan_unit", probes=[])["ok"]


def test_register_tools_scaling_csv_and_nonfinite(bridge: Bridge, modbus_server: int) -> None:
    assert request(bridge, "connect", transport="tcp", host="127.0.0.1", port=modbus_server)["ok"]
    row = {
        "name": "Temperature",
        "address": 0,
        "count": 2,
        "format": "u32",
        "scale": 0.1,
        "offset": -10,
        "unit": "C",
        "order": "CDAB",
    }
    result = request(bridge, "read_rows", rows=[row])["result"]["rows"][0]
    assert result["numeric"] == (101 * 65536 + 100) * 0.1 - 10
    encoded = request(bridge, "encode_values", row=row, text="10")["result"]["values"]
    assert encoded == [200, 0]
    bitmask = request(
        bridge, "read_rows", rows=[{"address": 0, "bitmask": True, "value_names": {"2": "Alarm"}}]
    )
    assert bitmask["ok"] and "Alarm" in bitmask["result"]["rows"][0]["display"]
    legacy_bitmask = request(
        bridge,
        "read_rows",
        rows=[{
            "address": 0,
            "format": "dec",
            "bitmask": True,
            "value_names": {"2": "Alarm"},
        }],
    )
    assert legacy_bitmask["ok"] and "Alarm" in legacy_bitmask["result"]["rows"][0]["display"]
    exported = request(bridge, "csv_export", rows=[row])["result"]["text"]
    parsed = request(bridge, "csv_parse", text=exported)["result"]["rows"][0]
    assert parsed["name"] == "Temperature" and parsed["order"] == "CDAB"
    assert parsed["scale"] == 0.1
    legacy_csv = request(
        bridge, "csv_parse",
        text="name,kind,address,format,poll_ms\nLegacy,holding_registers,0,dec,100\n",
    )["result"]["rows"][0]
    assert legacy_csv["format"] == "u16"
    assert legacy_csv["poll_ms"] is None
    assert request(
        bridge,
        "csv_parse",
        text="n,t,a\nX,coils,0\n",
        mapping={"n": "name", "t": "kind", "a": "address"},
    )["ok"]
    assert not request(bridge, "read_rows", rows=[row, {"address": -1}])["ok"]
    assert not request(bridge, "encode_values", row=row, text="nan")["ok"]


def test_logger_wide_csv_jsonl_and_disconnect(bridge: Bridge, tmp_path) -> None:
    rows = [{"name": "Speed", "address": 0, "scale": 0.1}, {"name": "State", "address": 1}]
    path = tmp_path / "samples.csv"
    assert request(bridge, "logger_start", rows=rows, path=str(path), interval_ms=100)["ok"]
    assert path.exists()
    assert request(bridge, "logger_sample", values=[[100], [3]])["result"]["rows_written"] == 1
    assert request(bridge, "logger_sample", values=[[200], [4]])["result"]["rows_written"] == 1
    assert "10" in path.read_text() and "Speed@0/u1" in path.read_text()
    assert not request(bridge, "logger_sample", values=[[100]])["ok"]
    assert request(bridge, "disconnect")["ok"]
    assert not request(bridge, "logger_status")["result"]["active"]
    path = tmp_path / "samples.jsonl"
    assert request(bridge, "logger_start", rows=rows, path=str(path), format="jsonl")["ok"]
    assert request(bridge, "logger_sample", values=[[100], [3]])["ok"]
    records = [json.loads(line) for line in path.read_text().splitlines()]
    assert records[0]["name"] == "Speed" and records[0]["value"] == "10"
    assert records[1]["name"] == "State"


def test_alarm_priority_and_scaling(bridge: Bridge, modbus_server: int) -> None:
    assert request(bridge, "connect", transport="tcp", host="127.0.0.1", port=modbus_server)["ok"]
    row = {
        "address": 0,
        "scale": 0.1,
        "alarms": [
            {"condition": "in_range", "value": 9, "value2": 11, "color": "yellow", "sound": True},
            {"condition": "gt", "value": 1, "color": "red"},
        ],
    }
    alarm = request(bridge, "read_rows", rows=[row])["result"]["rows"][0]["alarm"]
    assert alarm["color"] == "yellow" and alarm["sound"]


def free_port() -> int:
    import socket

    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def test_simulator_panel_commands_rules_and_external_master(bridge: Bridge) -> None:
    import time

    from modbus_connector.backend import ModbusBackend
    from modbus_connector.models import TcpParams

    port = free_port()
    rows = [{"name": "Counter", "address": 0, "count": 1, "values": [5], "rule_text": "prev+1"}]
    assert request(bridge, "sim_configure", rows=rows)["ok"]
    assert request(
        bridge,
        "device_start",
        mode="simulator",
        tick_ms=100,
        listen={"transport": "tcp", "host": "127.0.0.1", "port": port},
    )["ok"]
    master = ModbusBackend()
    try:
        master.connect(TcpParams("127.0.0.1", port))
        assert master.read(1, "holding_registers", 0, 1)[0] >= 5
        deadline = time.monotonic() + 2
        while master.read(1, "holding_registers", 0, 1)[0] <= 5:
            assert time.monotonic() < deadline
            time.sleep(0.02)
        assert request(bridge, "sim_set", row={"address": 1}, values=[321])["ok"]
        assert master.read(1, "holding_registers", 1, 1) == [321]
        status = request(bridge, "device_status")["result"]
        assert status["simulator"] and status["events"]
        assert not request(bridge, "sim_configure", rows=[{"address": 10000}])["ok"]
        invalid = request(bridge, "sim_configure", rows=[{"rule_text": '__import__("os")'}])
        assert invalid["ok"] and invalid["result"]["rule_errors"]["0"]["code"] == "invalid_rule"
    finally:
        master.disconnect()
    assert request(bridge, "device_stop")["ok"]
    assert not request(bridge, "device_status")["result"]["simulator"]


def test_gateway_panel_commands_forward_real_tcp(bridge: Bridge, modbus_server: int) -> None:
    from modbus_connector.backend import ModbusBackend
    from modbus_connector.models import TcpParams

    port = free_port()
    assert request(
        bridge,
        "device_start",
        mode="gateway",
        units=[1],
        listen={"transport": "tcp", "host": "127.0.0.1", "port": port},
        target={"transport": "tcp", "host": "127.0.0.1", "port": modbus_server},
    )["ok"]
    master = ModbusBackend()
    try:
        master.connect(TcpParams("127.0.0.1", port))
        assert master.read(1, "holding_registers", 0, 2) == [100, 101]
        master.write(1, "holding_registers", 0, [555])
        assert master.read(1, "holding_registers", 0, 1) == [555]
    finally:
        master.disconnect()
    assert request(bridge, "device_status")["result"]["gateway"]
    bridge.close()
    assert not bridge.devices.gateway.running


def test_sniffer_panel_commands_with_real_serial_pty(bridge: Bridge) -> None:
    import time

    from modbus_connector.sniffer_backend import crc16

    if sys.platform == "win32":
        pytest.skip("POSIX pseudo terminal")
    master_fd, slave_fd = os.openpty()
    try:
        port = os.ttyname(slave_fd)
        assert request(
            bridge, "device_start", mode="sniffer", listen={"transport": "rtu", "port": port}
        )["ok"]
        body = bytes([1, 6, 0, 5, 0, 77])
        os.write(master_fd, body + crc16(body).to_bytes(2, "little"))
        deadline = time.monotonic() + 2
        while True:
            result = request(bridge, "sniffer_snapshot", unit=1)["result"]
            if result["areas"].get("holding_registers", {}).get(5) == 77:
                break
            assert time.monotonic() < deadline
            time.sleep(0.02)
        status = request(bridge, "device_status")["result"]
        assert status["sniffer"] and any(e["event"] == "values" for e in status["events"])
        assert request(bridge, "device_stop")["ok"]
        assert not bridge.devices.sniffer.running
    finally:
        os.close(master_fd)
        os.close(slave_fd)


def test_templates_public_and_isolated_custom_history(
    bridge: Bridge, tmp_path, monkeypatch, cloud_template_cache,
) -> None:
    del cloud_template_cache
    monkeypatch.setenv("MODBUS_FLUTTER_HOME", str(tmp_path))
    catalog = request(bridge, "template_list")["result"]
    assert catalog["public"] and catalog["custom"] == []
    state = request(bridge, "template_load", resource="Acme/TestMeter")["result"]["state"]
    assert state["connection"]["baudrate"] == 2400 and len(state["registers"]) > 1
    state["query"] = {"kind": "holding_registers", "address": 5, "count": 10}
    state["sniffed"] = {"1": {"holding_registers/0": {"name": "Observed", "value": 7}}}
    saved = request(bridge, "template_save", state=state, name="My meter")["result"]
    template_id = saved["id"]
    assert request(bridge, "template_save", state=state, template_id=template_id)["ok"]
    versions = request(bridge, "template_versions", template_id=template_id)["result"]["versions"]
    assert len(versions) == 2
    loaded = request(
        bridge, "template_load", template_id=template_id, version_id=versions[-1]["id"]
    )["result"]["state"]
    assert loaded["query"]["address"] == 5
    assert loaded["sniffed"] == state["sniffed"]
    assert request(bridge, "template_rename", template_id=template_id, name="Renamed")["ok"]
    assert request(
        bridge, "template_delete_version", template_id=template_id, version_id=versions[0]["id"]
    )["ok"]
    assert not request(
        bridge, "template_delete_version", template_id=template_id, version_id=versions[-1]["id"]
    )["ok"]
    assert request(bridge, "template_delete", template_id=template_id)["ok"]
    assert request(bridge, "template_list")["result"]["custom"] == []


def test_advanced_functions_and_invalid_ranges(bridge: Bridge, modbus_server: int) -> None:
    assert request(bridge, "connect", transport="tcp", host="127.0.0.1", port=modbus_server)["ok"]
    assert request(bridge, "mask_write", address=0, and_mask=0, or_mask=17)["ok"]
    assert request(bridge, "read", address=0)["result"]["values"] == [17]
    result = request(
        bridge, "read_write", read_address=0, read_count=2, write_address=1, values=[123]
    )
    assert result["result"]["values"] == [17, 123]
    assert not request(bridge, "read_write", write_address=65535, values=[1, 2])["ok"]
    assert not request(bridge, "mask_write", and_mask=True)["ok"]
    assert not request(bridge, "diagnostics", action="unknown")["ok"]


def test_expressions_safe_engine_and_alarm_results(bridge: Bridge) -> None:
    result = request(
        bridge,
        "evaluate_expressions",
        values={"Voltage": 230, "Current": 5},
        expressions=[
            {
                "name": "Power",
                "text": "[Voltage]*[Current]",
                "alarms": [{"condition": "gt", "value": 1000}],
            },
            {"text": "[missing]"},
            {"text": "1/0"},
            {"text": '__import__("os").system("false")'},
        ],
    )["result"]["rows"]
    assert result[0]["numeric"] == 1150 and result[0]["alarm"]
    assert all(r["numeric"] is None and r["error"] for r in result[1:])


def test_grouped_reads_reuse_planner_and_fall_back_per_row(
    bridge: Bridge, modbus_server: int, monkeypatch
) -> None:
    assert request(bridge, "connect", transport="tcp", host="127.0.0.1", port=modbus_server)["ok"]
    rows = [
        {"name": "Pair", "address": 0, "count": 2, "format": "u32"},
        {"name": "Next", "address": 2},
        {"name": "Timed", "address": 3, "poll_ms": 1000},
    ]
    assert request(bridge, "plan_reads", rows=rows)["result"]["groups"] == [[0, 1, 2]]
    calls = []
    original = bridge.backend.read

    def read(unit, kind, address, count):
        calls.append((address, count))
        return original(unit, kind, address, count)

    monkeypatch.setattr(bridge.backend, "read", read)
    result = request(bridge, "read_rows", rows=rows, grouped=True)["result"]["rows"]
    assert calls == [(0, 4)]
    assert result[0]["values"] == [100, 101] and result[1]["values"] == [102]

    def fail_group(unit, kind, address, count):
        if count == 4:
            raise ValueError("group rejected")
        return original(unit, kind, address, count)

    monkeypatch.setattr(bridge.backend, "read", fail_group)
    assert request(bridge, "read_rows", rows=rows, grouped=True)["result"]["rows"] == result


def test_csv_exports_display_values_and_preserves_importable_metadata(bridge: Bridge) -> None:
    import csv

    rows = [
        {"name": "Temperature", "address": 0, "scale": 0.1, "unit": "C", "values": [123]},
        {"name": "Sniffed", "address": 1, "format": "hex", "value": 255},
        {"name": "Missing", "address": 2},
    ]
    exported = request(bridge, "csv_export", rows=rows, include_values=True)["result"]["text"]
    records = list(csv.DictReader(io.StringIO(exported)))
    assert "12.3" in records[0]["value"]
    assert "FF" in records[1]["value"].upper()
    assert records[2]["value"] == ""
    imported = request(bridge, "csv_parse", text=exported)["result"]["rows"]
    assert len(imported) == 3 and imported[0]["scale"] == 0.1
    selected = request(bridge, "csv_export", rows=rows[:1], columns=["name", "value"])
    assert list(csv.DictReader(io.StringIO(selected["result"]["text"])))[0]["name"] == "Temperature"


@pytest.mark.parametrize("row_count", [512, 1832, 4096])
def test_full_register_map_fits_bounded_protocol_frames(row_count: int) -> None:
    rows = [
        {
            "name": f"Register {i} " + "x" * 200,
            "address": i,
            "count": 1,
            "format": "dec",
            "kind": "holding_registers",
            "scale": 1,
            "offset": 0,
        }
        for i in range(row_count)
    ]
    frame = json.dumps({"id": 1, "command": "plan_reads", "unit": 1, "rows": rows}) + "\n"
    assert 65536 < len(frame) < MAX_LINE
    sink = io.StringIO()
    serve(io.StringIO(frame), sink)
    result = json.loads(sink.getvalue())
    assert result["ok"]
    assert sum(len(group) for group in result["result"]["groups"]) == row_count


def test_large_template_csv_round_trip_keeps_all_rows(bridge):
    rows = [{"name": f"Register {i}", "address": i, "count": 1} for i in range(1832)]
    exported = request(bridge, "csv_export", rows=rows)
    assert exported["ok"], exported
    imported = request(bridge, "csv_parse", text=exported["result"]["text"])
    assert imported["ok"], imported
    assert len(imported["result"]["rows"]) == len(rows)


def test_render_rows_decodes_multiword_without_bus_io(bridge: Bridge, monkeypatch) -> None:
    monkeypatch.setattr(bridge.backend, "read", lambda *_: pytest.fail("Display must not read bus"))
    row = {
        "name": "Wide",
        "kind": "holding_registers",
        "address": 3,
        "count": 2,
        "format": "u32",
        "values": [1, 2],
    }
    result = request(bridge, "render_rows", rows=[row])
    assert result["ok"] and result["result"]["rows"][0]["numeric"] == 65538
    assert not request(bridge, "render_rows", rows=[{**row, "values": [1]}])["ok"]
    assert not request(bridge, "render_rows", rows=[{**row, "values": [1, -1]}])["ok"]


def test_simulator_invalid_rule_is_per_row_and_valid_rules_continue(bridge: Bridge) -> None:
    import socket
    import time

    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    base = {"kind": "holding_registers", "count": 1, "format": "dec"}
    configured = request(
        bridge,
        "sim_configure",
        rows=[
            {**base, "name": "Good", "address": 0, "rule_text": "prev+1"},
            {**base, "name": "Bad", "address": 1, "rule_text": "("},
            {**base, "name": "Missing", "address": 2, "rule_text": "[Absent]"},
        ],
    )
    assert configured["ok"]
    assert configured["result"]["rule_errors"]["1"]["code"] == "invalid_rule"
    assert request(
        bridge,
        "device_start",
        mode="simulator",
        tick_ms=100,
        listen={"transport": "tcp", "host": "127.0.0.1", "port": port},
    )["ok"]
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        status = request(bridge, "device_status")["result"]
        if status["rows"][0]["numeric"] > 0:
            break
        time.sleep(0.03)
    assert status["rows"][0]["numeric"] > 0
    assert status["rule_errors"]["2"]["code"] == "missing_reference"
    assert status["rows"][1]["values"] == [0]
    assert request(bridge, "device_stop")["ok"]


@pytest.mark.parametrize("fmt", ["csv", "jsonl"])
def test_logger_expressions_share_safe_engine_without_changing_map_csv(
    bridge: Bridge, tmp_path, fmt
) -> None:
    path = tmp_path / f"expressions.{fmt}"
    expressions = [
        {"name": "Double", "text": "[Voltage]*2"},
        {"name": "Missing", "text": "[Absent]"},
    ]
    assert request(
        bridge,
        "logger_start",
        path=str(path),
        format=fmt,
        rows=[],
        expressions=expressions,
        append=False,
    )["ok"]
    reply = request(bridge, "logger_sample", values=[], expression_values={"Voltage": 12.5})
    assert reply["ok"] and reply["result"]["expressions"][0]["numeric"] == 25
    assert reply["result"]["expressions"][1]["error"]
    assert request(bridge, "logger_stop")["ok"]
    content = path.read_text(encoding="utf-8-sig")
    if fmt == "csv":
        import csv

        rows = list(csv.reader(io.StringIO(content)))
        assert rows[0] == ["timestamp", "fx Double", "fx Missing"]
        assert rows[1][1:] == ["25", "—"]
        # Expression columns take part in the existing incompatible-header check.
        assert not request(
            bridge,
            "logger_start",
            path=str(path),
            rows=[],
            expressions=[expressions[0]],
            append=True,
        )["ok"]
    else:
        rows = [json.loads(line) for line in content.splitlines()]
        assert rows[0]["name"] == "Double" and rows[0]["kind"] == "expression"
        assert rows[0]["value"] == "25" and rows[1]["value"] == "—"

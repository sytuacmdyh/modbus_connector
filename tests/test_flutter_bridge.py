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


def test_scanner_real_backend(bridge: Bridge, modbus_server: int) -> None:
    assert request(bridge, 'connect', transport='tcp', host='127.0.0.1', port=modbus_server)['ok']
    result = request(bridge, 'scan_unit', unit=1, probes=[
        {'kind': 'holding_registers', 'address': 0, 'count': 1},
        {'kind': 'holding_registers', 'address': 60000, 'count': 1},
    ])
    assert result['result']['hits'] == [0]
    assert request(bridge, 'scan_address', address=0)['result']['values'] == [100, 101]
    assert request(bridge, 'scan_address', address=60000)['result']['values'] == []
    assert not request(bridge, 'scan_unit', probes=[{'address': 65535, 'count': 2}])['ok']
    assert not request(bridge, 'scan_unit', probes=[])['ok']

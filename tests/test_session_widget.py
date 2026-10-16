import os
import threading
import time
from collections.abc import Iterator
from unittest.mock import MagicMock

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

# Qt needs system libraries (libEGL etc.) that headless Linux CI runners lack;
# skip the whole module there — it still runs on macOS/Windows CI and dev machines.
try:
    from PySide6.QtWidgets import QApplication, QSizePolicy  # noqa: E402
except ImportError as exc:
    pytest.skip(f"Qt system libraries not available: {exc}", allow_module_level=True)

from modbus_connector.session_widget import SessionWidget  # noqa: E402


@pytest.fixture(scope="module")
def qapp() -> QApplication:
    return QApplication.instance() or QApplication([])


@pytest.mark.parametrize("failed", [False, True])
def test_stop_polling_cancels_reads_and_late_logs(qapp: QApplication, failed: bool) -> None:
    session = SessionWidget()
    started, release = threading.Event(), threading.Event()
    reads = []

    def delayed_read(*args):
        reads.append(args)
        started.set()
        assert release.wait(2)
        if failed:
            raise TimeoutError("no response")
        return [42]

    session._worker._backend.read = delayed_read
    session.connection_panel.set_connected(True, "Connected")
    session._on_connection_changed(True, "Connected")
    panel = session.registers_panel
    panel.set_state([{"address": i * 2, "count": 1} for i in range(10)])
    panel.start_polling(False)
    panel.read_all()
    assert started.wait(1)
    # Deliver the first read's start log before clicking Stop.
    qapp.processEvents()
    panel._poll_button.click()
    stopped_log = session.log_panel._edit.toPlainText()
    release.set()
    try:
        deadline = time.monotonic() + 0.2
        while time.monotonic() < deadline:
            qapp.processEvents()
            time.sleep(0.001)
        assert len(reads) == 1
        assert session.log_panel._edit.toPlainText() == stopped_log
        assert session.connection_panel._connected
        assert panel._read_all_button.isEnabled()
        # A new manual read after Stop must still work without reconnecting.
        session._worker._backend.read = lambda *args: [123]
        panel._read_table_row(0)
        deadline = time.monotonic() + 1
        while panel._pending_reads and time.monotonic() < deadline:
            qapp.processEvents()
            time.sleep(0.001)
        assert panel._last_values[panel.row_tokens()[0]] == [123]
    finally:
        release.set()
        session.shutdown()


@pytest.mark.parametrize("language, expected", [
    ("zh_CN", "设备未响应"), ("en", "No response"), ("ru", "Устройство не ответило"),
])
@pytest.mark.parametrize("detail", [
    "No Response received from the remote slave/Unable to decode response",
    "Modbus Error: [Input/Output] Modbus Error: [Invalid Message] "
    "No response received, expected at least 4 bytes (0 received)",
])
def test_read_error_uses_current_language(qapp, language, expected, detail) -> None:
    from pymodbus.exceptions import ModbusIOException

    from modbus_connector.i18n import set_language
    from modbus_connector.models import RegisterRow
    from modbus_connector.worker import ModbusWorker

    set_language(language)
    worker = ModbusWorker()
    client = MagicMock()
    client.read_holding_registers.return_value = ModbusIOException(detail)
    worker._backend._client = client
    logs, results = [], []
    worker.logLine.connect(logs.append)
    worker.readFinished.connect(lambda *args: results.append(args))
    worker.read(1, 1, RegisterRow("", "holding_registers", 0, 13))
    assert expected in logs[-1]
    assert expected in results[-1][-1]
    assert "Modbus Error:" not in logs[-1]
    if "4 bytes" in detail:
        assert "4" in results[-1][-1] and "0" in results[-1][-1]
    if language != "ru":
        assert not any("\u0400" <= char <= "\u04ff" for char in logs[-1])


@pytest.mark.parametrize("closing", [False, True])
def test_disconnect_skips_queued_reads(qapp: QApplication, closing: bool) -> None:
    session = SessionWidget()
    started = threading.Event()
    release = threading.Event()
    reads = []

    def slow_read(*args):
        reads.append(args)
        started.set()
        release.wait(2)
        time.sleep(0.04)
        raise TimeoutError("wrong port: no response")

    session._worker._backend.read = slow_read
    session.connection_panel.set_connected(True, "Connected")
    session._on_connection_changed(True, "Connected")
    session.registers_panel.set_state([
        {"address": i * 2, "count": 1} for i in range(20)
    ])
    session.registers_panel.start_polling(False)
    session.registers_panel.read_all()
    assert started.wait(1)
    before = time.monotonic()
    try:
        if closing:
            release.set()
            session.shutdown()
        else:
            session.connection_panel._button.click()
            release.set()
            deadline = before + 0.3
            while session.connection_panel._connected and time.monotonic() < deadline:
                qapp.processEvents()
                time.sleep(0.001)
            assert not session.connection_panel._connected
        assert time.monotonic() - before < 0.3
        assert len(reads) == 1
        assert not session.registers_panel.is_polling()
        assert not session.registers_panel._pending_reads
    finally:
        release.set()
        session.shutdown()


@pytest.fixture(autouse=True)
def _destroy_sessions(qapp: QApplication) -> Iterator[None]:
    yield
    # a leaked session's table can crash a later app-wide stylesheet switch
    # (QTableView.updateEditorGeometries); destroy sessions after each test
    # (shutdown() is idempotent)
    for widget in QApplication.topLevelWidgets():
        if isinstance(widget, SessionWidget):
            widget.shutdown()
            widget.close()
            widget.deleteLater()
    qapp.processEvents()


def test_state_roundtrip_and_shutdown(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state(
        {
            "connection": {"type": "TCP", "tcp_host": "10.0.0.1", "tcp_port": 1502,
                           "unit": 7},
            "registers": [
                {"name": "temp", "kind": "holding_registers", "address": 5, "count": 2,
                 "format": "f32", "unit_id": "3", "poll_ms": "5000"}
            ],
            "scanner": {"start": 5, "end": 9},
        }
    )
    collected = session.state()
    connection = collected["connection"]
    assert connection["tcp_host"] == "10.0.0.1"
    assert connection["tcp_port"] == 1502
    assert connection["unit"] == 7
    row = collected["registers"][0]
    assert row["name"] == "temp"
    assert row["format"] == "f32"
    assert row["unit_id"] == "3"
    assert row["poll_ms"] == "5000"
    assert collected["scanner"]["start"] == 5
    assert collected["scanner"]["end"] == 9
    session.shutdown()  # must stop the worker thread without hanging


def test_registers_options_roundtrip(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state({"registers_options": {"order": "CDAB"}})
    assert session.state()["registers_options"]["order"] == "CDAB"
    session.set_state({"registers_options": {"order": "junk"}})  # invalid: keep
    assert session.state()["registers_options"]["order"] == "CDAB"
    session.set_state({"registers": []})  # missing key: keep current value
    assert session.state()["registers_options"]["order"] == "CDAB"
    session.shutdown()


def test_trend_defaults_apply_before_creating_rows(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state({
        "registers_options": {"trend_enabled": False},
        "registers": [
            {"address": 0, "count": 1},
            {"address": 1, "count": 1, "trend_enabled": True},
        ],
    })
    panel = session.registers_panel
    first, second = panel.row_tokens()
    assert panel.series(first) is None
    assert panel.series(second) is not None
    assert panel.state()[1]["trend_enabled"] is True
    session.shutdown()


def test_column_widths_roundtrip(qapp: QApplication) -> None:
    session = SessionWidget()
    session.registers_panel._table.setColumnWidth(0, 222)
    widths = session.state()["registers_options"]["column_widths"]
    assert widths[0] == 222
    assert len(widths) == session.registers_panel._table.columnCount()

    fresh = SessionWidget()
    fresh.set_state({"registers_options": {"column_widths": widths}})
    header = fresh.registers_panel._table.horizontalHeader()
    assert header.sectionSize(0) == 222
    assert header.sectionSize(1) == widths[1]
    session.shutdown()
    fresh.shutdown()


def test_logging_settings_roundtrip(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state(
        {"logging": {"path": "/tmp/x.jsonl", "format": "jsonl",
                     "fields": ["name"], "append": False}}
    )
    assert session.state()["logging"] == {"path": "/tmp/x.jsonl", "format": "jsonl",
                                          "fields": ["name"], "append": False}
    session.set_state({"registers": []})  # missing key: keep current value
    assert session.state()["logging"]["format"] == "jsonl"
    session.shutdown()


def test_status_label_never_widens_the_window(qapp: QApplication) -> None:
    session = SessionWidget()
    policy = session.connection_panel._status.sizePolicy()
    assert policy.horizontalPolicy() == QSizePolicy.Policy.Ignored
    session.shutdown()


def test_bus_controls_follow_connection(qapp: QApplication, tmp_path) -> None:
    session = SessionWidget()
    panel = session.registers_panel
    scanner = session.scanner_panel
    assert not panel._read_all_button.isEnabled()  # starts disconnected
    assert not scanner._start_button.isEnabled()
    assert not scanner._addr_start_button.isEnabled()

    session._show_graph()
    graph = session._graph_window
    assert graph is not None
    assert not graph._poll_button.isEnabled()

    session._on_connection_changed(True, "Connected")  # worker signal path
    assert panel._read_all_button.isEnabled()
    assert scanner._start_button.isEnabled()
    assert scanner._addr_start_button.isEnabled()
    assert graph._poll_button.isEnabled()

    # polling + logging active when the connection drops: both must stop
    panel.set_logging_state({"path": str(tmp_path / "bus.csv")})
    panel.start_logging()
    assert panel.is_polling() and panel.is_logging()
    session._on_connection_changed(False, "Disconnected")
    assert not panel.is_polling() and not panel.is_logging()
    assert not panel._poll_button.isEnabled()
    assert not scanner._start_button.isEnabled()
    assert not graph._poll_button.isEnabled()
    session.shutdown()
    # destroy the widget tree (it holds a GraphWindow) so no dangling wrapper
    # survives into later palette/layout passes — see tests/test_graph_window
    session.deleteLater()
    qapp.processEvents()


def test_slave_mode_state_roundtrip(qapp: QApplication) -> None:
    session = SessionWidget()
    assert session.state()["mode"] == "master"  # default / backward compat
    session.set_state(
        {
            "mode": "slave",
            "sim": {
                "server": {"type": "TCP", "host": "0.0.0.0", "port": 1600, "unit": 3},
                "rows": [
                    {"name": "x", "kind": "coils", "address": 0, "count": 1,
                     "values": [True]}
                ],
            },
        }
    )
    collected = session.state()
    assert collected["mode"] == "slave"
    assert collected["sim"]["server"]["port"] == 1600
    assert collected["sim"]["server"]["unit"] == 3
    assert collected["sim"]["rows"][0]["values"] == [True]
    # master-часть state на месте
    assert "connection" in collected and "registers" in collected
    session.set_state({"mode": "junk"})  # неизвестный режим игнорируется
    assert session.state()["mode"] == "slave"
    session.shutdown()


def test_slave_mode_visibility(qapp: QApplication) -> None:
    session = SessionWidget()
    assert session._center_stack.currentWidget() is session.registers_panel
    session.set_state({"mode": "slave"})
    assert session._center_stack.currentWidget() is session.sim_panel
    assert session.connection_panel.isHidden()
    assert session._scanner_button.isHidden()
    assert session._graph_button.isHidden()
    session.set_state({"mode": "master"})
    assert session._center_stack.currentWidget() is session.registers_panel
    assert not session.connection_panel.isHidden()
    assert not session._scanner_button.isHidden()
    session.shutdown()


def test_mode_combo_locking(qapp: QApplication) -> None:
    session = SessionWidget()
    combo = session._mode_combo
    assert combo.isEnabled()
    # master подключён — режим менять нельзя
    session._on_connection_changed(True, "Connected (tcp 127.0.0.1:502)")
    assert not combo.isEnabled()
    session._on_connection_changed(False, "Disconnected")
    assert combo.isEnabled()
    # sim-сервер запущен — тоже нельзя
    session.set_state({"mode": "slave"})
    session._on_sim_server_changed(True, "Simulator running (tcp 127.0.0.1:1502)")
    assert not combo.isEnabled()
    assert session.title() == "Simulator"  # panel не знает params — общий ключ
    session._on_sim_server_changed(False, "Stopped")
    assert combo.isEnabled()
    session.shutdown()


def test_slave_title_follows_server(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state({"mode": "slave"})
    assert session.title() == "Simulator"
    # запуск из панели: params известны → заголовок с описанием сервера;
    # startRequested отключён от worker'а, чтобы не поднять реальный сервер
    session.sim_panel.startRequested.disconnect()
    session.sim_panel._button.click()
    session.sim_panel.set_running(True, "Simulator running (tcp 127.0.0.1:1502)")
    session._on_sim_server_changed(True, "Simulator running (tcp 127.0.0.1:1502)")
    assert session.title() == "sim tcp 127.0.0.1:1502"
    session.sim_panel.set_running(False, "Stopped")
    session._on_sim_server_changed(False, "Stopped")
    assert session.title() == "Simulator"
    session.shutdown()


def test_shutdown_in_slave_mode(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state({"mode": "slave"})
    session.shutdown()  # оба потока останавливаются без зависания
    session.shutdown()  # идемпотентно


def test_sniffer_mode_state_roundtrip(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state(
        {
            "mode": "sniffer",
            "sniffer": {
                "params": {"port": "/dev/ttyFAKE0", "baudrate": 19200, "parity": "E"},
                "units": [
                    {"unit": 3, "rows": [
                        {"address": 5, "kind": "holding_registers", "name": "temp",
                         "format": "f32", "value": [100, 200]},
                    ]},
                ],
            },
        }
    )
    collected = session.state()
    assert collected["mode"] == "sniffer"
    sniffer = collected["sniffer"]
    assert sniffer["params"]["port"] == "/dev/ttyFAKE0"
    assert sniffer["params"]["baudrate"] == 19200
    assert sniffer["params"]["parity"] == "E"
    assert sniffer["units"][0]["unit"] == 3
    assert sniffer["units"][0]["rows"][0]["value"] == [100, 200]
    # master/slave-части state на месте
    assert "connection" in collected and "sim" in collected
    session.shutdown()


def test_sniffer_mode_visibility(qapp: QApplication) -> None:
    session = SessionWidget()
    assert session._center_stack.currentWidget() is session.registers_panel
    session.set_state({"mode": "sniffer"})
    assert session._center_stack.currentWidget() is session.sniffer_panel
    assert session.connection_panel.isHidden()
    assert session._scanner_button.isHidden()
    assert session._graph_button.isHidden()
    session.set_state({"mode": "master"})
    assert session._center_stack.currentWidget() is session.registers_panel
    assert not session.connection_panel.isHidden()
    assert not session._scanner_button.isHidden()
    session.shutdown()


def test_sniffer_mode_lock_and_title(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state({"mode": "sniffer"})
    assert session._mode_combo.isEnabled()
    assert session.title() == "Sniffer"  # panel не знает params — общий ключ
    # активный сниффинг — режим менять нельзя, заголовок — описание порта
    session.sniffer_panel.set_state({"params": {"port": "/dev/ttyFAKE0"}})
    session.sniffer_panel.startRequested.disconnect()  # не поднимать реальный порт
    session.sniffer_panel._button.click()
    session.sniffer_panel.set_sniffing(True, "Listening (sniff rtu /dev/ttyFAKE0 @ 9600)")
    session._on_sniffing_changed(True, "Listening (sniff rtu /dev/ttyFAKE0 @ 9600)")
    assert not session._mode_combo.isEnabled()
    assert session.title() == "sniff rtu /dev/ttyFAKE0 @ 9600"
    session.sniffer_panel.set_sniffing(False, "Stopped")
    session._on_sniffing_changed(False, "Stopped")
    assert session._mode_combo.isEnabled()
    assert session.title() == "Sniffer"
    session.shutdown()


def test_shutdown_in_sniffer_mode(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state({"mode": "sniffer"})
    session.shutdown()  # все три потока останавливаются без зависания
    session.shutdown()  # идемпотентно


def test_gateway_mode_state_roundtrip(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state(
        {
            "mode": "gateway",
            "gateway": {
                "listen": {"type": "TCP", "tcp_host": "0.0.0.0", "tcp_port": 5020},
                "target": {"type": "TCP", "tcp_host": "10.0.0.2", "tcp_port": 502},
                "units": "1, 5",
            },
        }
    )
    collected = session.state()
    assert collected["mode"] == "gateway"
    gateway = collected["gateway"]
    assert gateway["listen"]["tcp_port"] == 5020
    assert gateway["target"]["tcp_host"] == "10.0.0.2"
    assert gateway["units"] == "1, 5"
    # master/slave/sniffer-части state на месте
    assert "connection" in collected and "sim" in collected and "sniffer" in collected
    session.shutdown()


def test_gateway_mode_visibility(qapp: QApplication) -> None:
    session = SessionWidget()
    assert session._center_stack.currentWidget() is session.registers_panel
    session.set_state({"mode": "gateway"})
    assert session._center_stack.currentWidget() is session.gateway_panel
    assert session.connection_panel.isHidden()
    assert session._scanner_button.isHidden()
    assert session._graph_button.isHidden()
    session.set_state({"mode": "master"})
    assert session._center_stack.currentWidget() is session.registers_panel
    assert not session.connection_panel.isHidden()
    session.shutdown()


def test_gateway_mode_lock_and_title(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state({"mode": "gateway"})
    assert session._mode_combo.isEnabled()
    assert session.title() == "Gateway"  # panel не знает params — общий ключ
    # запущенный шлюз — режим менять нельзя, заголовок — описание сторон
    session.gateway_panel.startRequested.disconnect()  # не поднимать реальный сервер
    session.gateway_panel._button.click()
    session.gateway_panel.set_running(
        True, "Gateway running (gw tcp 0.0.0.0:1502 -> tcp 127.0.0.1:502)"
    )
    session._on_gateway_changed(
        True, "Gateway running (gw tcp 0.0.0.0:1502 -> tcp 127.0.0.1:502)"
    )
    assert not session._mode_combo.isEnabled()
    assert session.title() == "gw tcp 0.0.0.0:1502 -> tcp 127.0.0.1:502"
    session.gateway_panel.set_running(False, "Stopped")
    session._on_gateway_changed(False, "Stopped")
    assert session._mode_combo.isEnabled()
    assert session.title() == "Gateway"
    session.shutdown()


def test_shutdown_in_gateway_mode(qapp: QApplication) -> None:
    session = SessionWidget()
    session.set_state({"mode": "gateway"})
    session.shutdown()  # все четыре потока останавливаются без зависания
    session.shutdown()  # идемпотентно

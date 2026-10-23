"""Large maps must not allocate editors or history for every row."""
import itertools
import os
from collections.abc import Iterator

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
try:
    from PySide6.QtCore import QCoreApplication, QEvent, Qt
    from PySide6.QtWidgets import QApplication, QComboBox, QTableWidget
except ImportError as exc:
    pytest.skip(f"Qt unavailable: {exc}", allow_module_level=True)

from modbus_connector.registers_panel import (
    COL_ADDRESS,
    COL_FORMAT,
    COL_NAME,
    COL_TYPE,
    COL_UNIT_ID,
    COL_VALUE,
    RegistersPanel,
)


@pytest.fixture(scope="module")
def qapp() -> QApplication:
    return QApplication.instance() or QApplication([])


@pytest.fixture(autouse=True)
def destroy_panels(qapp: QApplication) -> Iterator[None]:
    yield
    for widget in QApplication.topLevelWidgets():
        if isinstance(widget, RegistersPanel):
            widget.close()
            widget.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)


def make_panel(rows: int = 3) -> RegistersPanel:
    panel = RegistersPanel(itertools.count(1).__next__)
    panel.set_state([
        {"name": f"r{i}", "kind": "holding_registers", "address": i, "count": 1}
        for i in range(rows)
    ])
    panel.set_bus_enabled(True)
    return panel


def test_default_reads_merge_contiguous_addresses_only(qapp: QApplication) -> None:
    panel = make_panel()
    panel._table.item(2, COL_ADDRESS).setText("3")
    reads = []
    panel.readRequested.connect(lambda *args: reads.append(args))
    panel.read_all()
    assert [(r[2].address, r[2].count) for r in reads] == [(0, 2), (3, 1)]


def test_effective_global_and_explicit_unit_merge(qapp: QApplication) -> None:
    panel = make_panel(2)
    panel.set_unit_id(5)
    panel._table.item(1, COL_UNIT_ID).setText("5")
    reads = []
    panel.readRequested.connect(lambda *args: reads.append(args))
    panel.read_all()
    assert len(reads) == 1
    assert (reads[0][1], reads[0][2].count) == (5, 2)


def test_only_current_row_has_editors(qapp: QApplication) -> None:
    panel = make_panel(100)
    assert panel._table.cellWidget(50, COL_TYPE) is None
    assert panel._table.cellWidget(50, COL_FORMAT) is None
    panel._table.setCurrentCell(50, COL_NAME)
    assert isinstance(panel._table.cellWidget(50, COL_TYPE), QComboBox)
    assert panel._table.cellWidget(0, COL_TYPE) is None
    assert len(panel.findChildren(QComboBox)) < 20
    assert panel.state()[70]["kind"] == "holding_registers"


def test_trend_default_and_row_override(qapp: QApplication) -> None:
    panel = make_panel()
    panel.set_options({"trend_enabled": False})
    panel.set_state([
        {"address": 0, "count": 1},
        {"address": 1, "count": 1, "trend_enabled": True},
    ])
    tokens = panel.row_tokens()
    assert not panel.row_trend_enabled(tokens[0])
    assert panel.row_trend_enabled(tokens[1])
    panel.start_polling(True)
    reads = []
    panel.readRequested.connect(lambda *args: reads.append(args))
    panel.read_all()
    panel.handle_read_finished(reads[0][0], True, [10, 20], "")
    panel.stop_polling()
    assert panel.series(tokens[0]) is None
    assert panel.series(tokens[1]).points()[1] == [20]
    assert panel._table.item(0, COL_VALUE).text() == "10"
    state = panel.state()
    clone = make_panel()
    clone.set_options(panel.options_state())
    clone.set_state(state)
    assert [clone.row_trend_enabled(t) for t in clone.row_tokens()] == [False, True]


def test_changed_values_reuse_flash_timer(qapp: QApplication) -> None:
    panel = make_panel(1)
    token = panel._token_at(0)
    for value in range(20):
        panel._read_table_row(0)
        rid = next(iter(panel._pending_reads))
        panel.handle_read_finished(rid, True, [value], "")
    from PySide6.QtCore import QTimer
    assert len(panel.findChildren(QTimer)) < 6
    assert panel._last_values[token] == [19]


def test_sorted_and_deleted_rows_keep_response_identity(qapp: QApplication) -> None:
    panel = make_panel()
    panel._table.item(0, COL_ADDRESS).setText("20")
    token = panel._token_at(0)
    panel._read_table_row(0)
    rid = next(iter(panel._pending_reads))
    panel._sort_by_address()
    assert panel._find_row_by_token(token) == 2
    panel.handle_read_finished(rid, True, [77], "")
    assert panel._table.item(2, COL_VALUE).text() == "77"
    panel._delete_row(0)
    assert panel._find_row_by_token(token) == 1


def test_editor_change_persists_after_selection_changes(qapp: QApplication) -> None:
    panel = make_panel()
    panel._table.setCurrentCell(0, COL_TYPE)
    combo = panel._table.cellWidget(0, COL_TYPE)
    combo.setCurrentText("coils")
    panel._table.setCurrentCell(1, COL_NAME)
    assert panel.state()[0]["kind"] == "coils"
    assert panel._row_data(0).kind == "coils"
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)


def test_failed_group_stays_individual_until_polling_stops(qapp: QApplication) -> None:
    panel = make_panel(2)
    reads = []
    panel.readRequested.connect(lambda *args: reads.append(args))
    panel.read_all()
    panel.handle_read_finished(reads[0][0], False, [], "Illegal Data Address")
    for rid, _unit, _row in reads[1:]:
        panel.handle_read_finished(rid, True, [10], "")
    reads.clear()
    panel.read_all()
    assert [r[2].count for r in reads] == [1, 1]
    panel.stop_polling()
    reads.clear()
    panel.read_all()
    assert [r[2].count for r in reads] == [2]


def test_saved_false_disables_grouping(qapp: QApplication) -> None:
    panel = make_panel(2)
    panel.set_options({"group_reads": False})
    reads = []
    panel.readRequested.connect(lambda *args: reads.append(args))
    panel.read_all()
    assert len(reads) == 2
    assert panel.options_state()["group_reads"] is False


def test_editors_stay_bounded_across_moves_and_theme_changes(qapp: QApplication) -> None:
    from modbus_connector import theme

    panel = make_panel(30)
    for i in range(30):
        panel._table.setCurrentCell(i, COL_NAME)
        if i % 10 == 0:
            panel._swap_rows(i, 29 - i)
            theme.apply_theme("light")
        qapp.processEvents()
        QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
    assert len(panel.findChildren(QComboBox)) < 20


def test_bulk_trend_setting_and_display_dialog(qapp: QApplication) -> None:
    panel = make_panel()
    panel._table.selectAll()
    changes = []
    panel.rowsChanged.connect(lambda: changes.append(True))
    panel._set_selected_trends(False)
    assert len(changes) == 1  # the graph rebuilds once for the whole selection
    assert not any(panel.row_trend_enabled(t) for t in panel.row_tokens())
    panel._on_display_settings()
    table = panel._display_dialog.findChild(QTableWidget)
    table.item(1, 6).setCheckState(Qt.CheckState.Checked)
    assert [panel.row_trend_enabled(t) for t in panel.row_tokens()] == [False, True, False]
    panel._display_dialog.close()

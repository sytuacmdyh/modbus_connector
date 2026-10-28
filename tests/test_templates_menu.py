import os
from collections.abc import Iterator

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

# Qt needs system libraries (libEGL etc.) that headless Linux CI runners lack;
# skip the whole module there — it still runs on macOS/Windows CI and dev machines.
try:
    from PySide6.QtWidgets import QApplication, QMenu  # noqa: E402
except ImportError as exc:
    pytest.skip(f"Qt system libraries not available: {exc}", allow_module_level=True)

from modbus_connector import custom_templates, main_window  # noqa: E402
from modbus_connector.custom_templates import CustomTemplateStore  # noqa: E402
from modbus_connector.custom_templates_dialog import CustomTemplatesDialog  # noqa: E402
from modbus_connector.i18n import set_language  # noqa: E402
from modbus_connector.main_window import MainWindow  # noqa: E402
from modbus_connector.templates import load_template  # noqa: E402
from tests.template_fixtures import FIXTURE_KEY, FIXTURE_TEMPLATE  # noqa: E402


@pytest.fixture(autouse=True)
def _public_template_cache(tmp_path, monkeypatch):
    from modbus_connector import templates
    from tests.template_fixtures import seed_primary_cloud_cache

    cache = tmp_path / "cloud_templates.json"
    seed_primary_cloud_cache(cache)
    monkeypatch.setattr(templates, "CLOUD_TEMPLATES_PATH", cache)


@pytest.fixture(scope="module")
def qapp() -> QApplication:
    return QApplication.instance() or QApplication([])


@pytest.fixture(autouse=True)
def isolated(monkeypatch, tmp_path):
    monkeypatch.setattr(custom_templates, "CUSTOM_TEMPLATES_PATH", tmp_path / "custom")
    monkeypatch.setattr(main_window, "load_settings", lambda: {})
    monkeypatch.setattr(main_window, "save_settings", lambda state: None)


@pytest.fixture(autouse=True)
def _destroy_windows(qapp: QApplication) -> Iterator[None]:
    yield
    for widget in QApplication.topLevelWidgets():
        if isinstance(widget, MainWindow):
            widget._shutdown_sessions()
            widget.close()
            widget.deleteLater()
    qapp.processEvents()


def _fresh_window() -> MainWindow:
    window = MainWindow()
    window._clear_sessions()  # drop whatever the user's settings file restored
    set_language("en")  # construction re-applied the persisted language; pin en
    return window


def _find_submenu(menu: QMenu, title: str) -> QMenu:
    for action in menu.actions():
        # one .menu() call, kept in a local: each call returns a new wrapper
        # and a discarded wrapper can delete the underlying C++ QMenu
        submenu = action.menu()
        if submenu is not None and submenu.title() == title:
            return submenu
    raise AssertionError(f"submenu {title!r} not found in {menu.title()!r}")


def test_templates_menu_structure(qapp: QApplication) -> None:
    window = _fresh_window()
    titles = [action.text() for action in window.menuBar().actions()]
    # Templates sits between File and View
    assert titles.index("Templates") == titles.index("File") + 1
    assert titles.index("Templates") == titles.index("View") - 1

    public = _find_submenu(window._templates_menu, "Public templates")
    acme = _find_submenu(public, "Acme")
    names = [action.text() for action in acme.actions()]
    assert any("Test Meter" in name for name in names)
    window._shutdown_sessions()


def test_template_action_opens_new_tab(qapp: QApplication) -> None:
    window = _fresh_window()
    window._add_session()
    public = _find_submenu(window._templates_menu, "Public templates")
    acme = _find_submenu(public, "Acme")
    action = next(a for a in acme.actions() if "Test Meter" in a.text())

    action.trigger()
    assert window._tabs.count() == 2
    session = window._tabs.widget(1)
    assert window._tabs.tabText(1) == action.text()

    rows = session.registers_panel.state()
    # compare against the template itself: its register list evolves
    # independently of the menu integration
    template = load_template(FIXTURE_KEY)
    expected = {(reg.get("name", ""), reg["address"]) for reg in template["registers"]}
    got = {(row["name"], row["address"]) for row in rows}
    assert len(rows) == len(template["registers"]) >= 2
    assert got == expected
    assert ("Voltage", 0) in got and ("Total active energy", 342) in got
    window._shutdown_sessions()


def test_templates_menu_title_retranslates(qapp: QApplication) -> None:
    window = _fresh_window()
    assert window._templates_menu.title() == "Templates"
    set_language("ru")
    assert window._templates_menu.title() == "Шаблоны"
    set_language("en")
    assert window._templates_menu.title() == "Templates"
    window._shutdown_sessions()


def test_save_public_as_custom_then_save_versions(qapp, monkeypatch):
    window = _fresh_window()
    public = _find_submenu(window._templates_menu, "Public templates")
    _find_submenu(public, "Acme").actions()[0].trigger()
    assert not window._save_version_action.isEnabled()
    monkeypatch.setattr(main_window.QInputDialog, "getText", lambda *a, **kw: ("My pump", True))
    window._save_custom_template(copy=True)
    store = CustomTemplateStore()
    info = store.list_templates()[0]
    session = window._tabs.currentWidget()
    assert session.property("custom_template_id") == info.id
    assert window._save_version_action.isEnabled()
    assert len(store.versions(info.id)) == 1
    session.registers_panel.set_state([{"name": "New", "address": 99, "count": 1}])
    window._save_version_action.trigger()
    assert len(store.versions(info.id)) == 2
    assert store.load(info.id)["registers"][0]["address"] == 99
    custom = _find_submenu(window._templates_menu, "Custom templates")
    custom.actions()[0].trigger()
    assert window._tabs.currentWidget().registers_panel.state()[0]["address"] == 99
    saved_session = window._tabs.currentWidget().state()
    window._add_session(saved_session)
    assert window._save_version_action.isEnabled()
    window._shutdown_sessions()


def test_manager_open_rename_delete_versions_and_template(qapp, monkeypatch):
    from PySide6.QtWidgets import QMessageBox

    store = CustomTemplateStore()
    info = store.save(load_template(FIXTURE_KEY), name="Personal")
    first = store.versions(info.id)[0]["id"]
    state = store.load(info.id)
    state["registers"] = [{"name": "Changed", "address": 123, "count": 1}]
    store.save(state, template_id=info.id)
    window = _fresh_window()
    dialog = CustomTemplatesDialog(window)
    dialog.openRequested.connect(window._open_custom_template)
    dialog.templatesChanged.connect(window._custom_templates_changed)
    try:
        assert dialog.versions.count() == 2
        dialog.versions.setCurrentRow(1)
        dialog._buttons["Open version"].click()
        assert window._tabs.currentWidget().property("custom_template_id") == info.id
        assert len(window._tabs.currentWidget().registers_panel.state()) == len(
            FIXTURE_TEMPLATE["registers"]
        )
        monkeypatch.setattr(main_window.QInputDialog, "getText",
                            lambda *a, **kw: ("Renamed", True))
        dialog._rename()
        assert window._tabs.tabText(window._tabs.currentIndex()) == "Renamed"
        monkeypatch.setattr(QMessageBox, "question", lambda *a, **kw: QMessageBox.No)
        dialog._delete_version()
        assert len(store.versions(info.id)) == 2
        monkeypatch.setattr(QMessageBox, "question", lambda *a, **kw: QMessageBox.Yes)
        dialog._delete_version()  # newest selected after refresh
        assert store.versions(info.id)[0]["id"] == first
        assert not dialog._buttons["Delete version…"].isEnabled()
        dialog._delete()
        assert not store.list_templates()
        assert not window._save_version_action.isEnabled()
        assert window._tabs.currentWidget().registers_panel.state()
    finally:
        dialog.deleteLater()
        window._shutdown_sessions()


def test_custom_simulator_template_and_language(qapp):
    store = CustomTemplateStore()
    store.save({
        "mode": "slave", "connection": {}, "registers": [],
        "sim": {"rows": [{"name": "Sim value", "kind": "holding_registers",
                          "address": 42, "count": 1, "values": [9]}]},
    }, name="Simulator")
    window = _fresh_window()
    session = window._add_session()
    menu = session.sim_panel._template_button.menu()
    _find_submenu(menu, "Custom templates").actions()[0].trigger()
    assert session.sim_panel.state()["rows"][0]["address"] == 42
    set_language("zh_CN")
    assert _find_submenu(window._templates_menu, "公共模板")
    menu = session.sim_panel._template_button.menu()
    assert _find_submenu(menu, "用户自定义模板")
    window._shutdown_sessions()


def test_public_template_cannot_claim_a_custom_identity(qapp, monkeypatch):
    from modbus_connector.templates import TemplateInfo

    store = CustomTemplateStore()
    info = store.save(load_template(FIXTURE_KEY), name="Personal")
    public_state = {**store.load(info.id), "custom_template_id": info.id}
    monkeypatch.setattr(main_window, "load_template", lambda _: public_state)
    window = _fresh_window()
    window._apply_template(TemplateInfo("Public", "Vendor", "Vendor/Public.json"))
    assert window._tabs.currentWidget().property("custom_template_id") is None
    assert not window._save_version_action.isEnabled()
    assert len(store.versions(info.id)) == 1
    window._shutdown_sessions()

import os
import threading
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

try:
    from PySide6.QtWidgets import QApplication, QGroupBox, QMessageBox
except ImportError as exc:
    pytest.skip(f"Qt system libraries not available: {exc}", allow_module_level=True)

from modbus_connector import cloud_sync, main_window, templates  # noqa: E402
from modbus_connector.cloud_dialog import CloudSyncDialog  # noqa: E402
from modbus_connector.cloud_sync import WebDavClient, atomic_json  # noqa: E402
from modbus_connector.i18n import set_language  # noqa: E402
from modbus_connector.main_window import MainWindow  # noqa: E402


@pytest.fixture(scope="module")
def qapp() -> QApplication:
    return QApplication.instance() or QApplication([])


@pytest.fixture(autouse=True)
def isolated(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(cloud_sync, "CLOUD_SETTINGS_PATH", tmp_path / "cloud.json")
    monkeypatch.setattr(templates, "CLOUD_TEMPLATES_PATH", tmp_path / "cloud_templates.json")
    monkeypatch.setattr(main_window, "load_settings", lambda: {})
    monkeypatch.setattr(main_window, "save_settings", lambda state: None)
    monkeypatch.setattr(main_window, "apply_theme", lambda name: None)


@pytest.fixture(autouse=True)
def cleanup(qapp: QApplication, isolated: None) -> Iterator[None]:
    yield
    for widget in QApplication.topLevelWidgets():
        if isinstance(widget, MainWindow):
            widget.close()
            widget.deleteLater()
        elif isinstance(widget, CloudSyncDialog):
            assert widget._task is None
            widget.close()
            widget.deleteLater()
    qapp.processEvents()


def wait_finished(qapp: QApplication, dialog: CloudSyncDialog) -> None:
    deadline = time.monotonic() + 5
    while dialog._task is not None and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.005)
    assert dialog._task is None


def make_dialog() -> CloudSyncDialog:
    dialog = CloudSyncDialog()
    dialog._url.setText("https://dav.example.com/folder/")
    dialog._username.setText("alice")
    dialog._password.setText("secret")
    return dialog


@pytest.mark.parametrize("operation", ["test", "templates"])
def test_requests_run_off_gui_thread_and_close_waits(
    qapp: QApplication, monkeypatch: pytest.MonkeyPatch, operation: str,
) -> None:
    entered = threading.Event()
    release = threading.Event()
    thread_ids: list[int] = []

    def finish_request(_client: WebDavClient, **kwargs: object) -> int:
        thread_ids.append(threading.get_ident())
        entered.set()
        assert release.wait(3)
        return 1

    method = "test_connection" if operation == "test" else "download_templates"
    monkeypatch.setattr(WebDavClient, method, finish_request)
    dialog = make_dialog()
    refreshed: list[bool] = []
    dialog.templatesUpdated.connect(lambda: refreshed.append(True))
    dialog.show()
    dialog._start(operation)
    try:
        assert entered.wait(2)
        assert not dialog._actions[0].isEnabled()
        qapp.processEvents()
        dialog.reject()
        assert dialog.isVisible()  # no QThread destroyed while running
        assert dialog._task.isInterruptionRequested()
    finally:
        release.set()
        wait_finished(qapp, dialog)
    assert thread_ids[0] != threading.get_ident()
    assert not dialog.isVisible()
    assert refreshed == ([True] if operation == "templates" else [])


def test_download_refreshes_main_and_simulator_menus(
    qapp: QApplication, monkeypatch: pytest.MonkeyPatch,
) -> None:
    def download(_client: WebDavClient, **kwargs: object) -> int:
        atomic_json(templates.CLOUD_TEMPLATES_PATH, {
            "CloudCo/Device.json": {"name": "New cloud device", "connection": {}, "registers": []},
        })
        return 1

    monkeypatch.setattr(WebDavClient, "download_templates", download)
    window = MainWindow()
    old_session = window._tabs.widget(0)
    before = window._collect_state()
    dialog = CloudSyncDialog(window)
    dialog.templatesUpdated.connect(window._refresh_templates)
    dialog._url.setText("https://dav.example.com/")
    dialog._start("templates")
    wait_finished(qapp, dialog)
    assert window._tabs.widget(0) is old_session
    assert window._collect_state() == before
    public = window._templates_menu.actions()[0].menu()
    assert any(a.text() == "CloudCo" for a in public.actions())
    sim_menu = window._tabs.widget(0).sim_panel._template_button.menu()
    sim_public = sim_menu.actions()[0].menu()
    assert any(a.text() == "CloudCo" for a in sim_public.actions())
    set_language("zh_CN")
    assert window._cloud_action.text() == "云端同步…"


def test_mode_hides_publisher_actions_and_blocks_programmatic_publish(qapp, monkeypatch):
    uploaded = []
    monkeypatch.setattr(WebDavClient, "publish_templates", lambda *a, **kw: uploaded.append(a))
    dialog = make_dialog()
    dialog.show()
    assert dialog._mode.currentData() == "consumer"
    assert all(button.isHidden() for button in dialog._publisher_actions)
    for operation in ("publish", "activate"):
        dialog._start(operation)
        assert dialog._task is None
        assert "Consumer mode" in dialog._status.text()
    assert uploaded == []
    dialog._mode.setCurrentIndex(dialog._mode.findData("publisher"))
    assert all(not button.isHidden() for button in dialog._publisher_actions)
    dialog._save_connection()
    assert cloud_sync.WebDavSettings.load().mode == "publisher"
    dialog._mode.setCurrentIndex(dialog._mode.findData("consumer"))
    assert all(button.isHidden() for button in dialog._publisher_actions)


def test_publish_requires_confirmation_and_snapshots_all_visible_templates(qapp, monkeypatch):
    published = []
    info = templates.TemplateInfo(name="Local", manufacturer="Maker", resource="Maker/Local.json")
    data = {"name": "Local", "connection": {}, "registers": []}
    monkeypatch.setattr(templates, "list_templates", lambda: [info])
    gui_thread = threading.get_ident()
    publish_threads = []

    def load_template(info):
        assert threading.get_ident() == gui_thread
        return data

    def publish(client, catalog, **kwargs):
        publish_threads.append(threading.get_ident())
        published.append(catalog)
        return "v1"

    monkeypatch.setattr(templates, "load_template", load_template)
    monkeypatch.setattr(WebDavClient, "publish_templates", publish)
    dialog = make_dialog()
    dialog._mode.setCurrentIndex(dialog._mode.findData("publisher"))
    monkeypatch.setattr(QMessageBox, "question", lambda *a: QMessageBox.StandardButton.No)
    dialog._start("publish")
    assert dialog._task is None and not published
    monkeypatch.setattr(QMessageBox, "question", lambda *a: QMessageBox.StandardButton.Yes)
    dialog._start("publish")
    wait_finished(qapp, dialog)
    assert published == [{"Maker/Local.json": data}]
    assert publish_threads[0] != gui_thread
    assert dialog._status.text() == "Published 1 templates. Version: v1"


def test_history_download_and_publisher_only_activation(qapp, monkeypatch):
    downloaded, activated = [], []
    monkeypatch.setattr(WebDavClient, "list_versions", lambda c: ["v2", "v1"])
    monkeypatch.setattr(WebDavClient, "download_templates",
                        lambda c, **kw: downloaded.append(kw["version"]) or 1)
    monkeypatch.setattr(WebDavClient, "activate_version",
                        lambda c, v, **kw: activated.append(v) or "v3")
    monkeypatch.setattr(QMessageBox, "question", lambda *a: QMessageBox.StandardButton.Yes)
    dialog = CloudSyncDialog()
    dialog._url.setText("https://dav.example.com/")
    assert all(not button.isEnabled() for button in dialog._version_actions)
    dialog._start("history")
    wait_finished(qapp, dialog)
    assert dialog._versions.count() == 2
    assert dialog._version_actions[0].isEnabled()
    dialog._versions.setCurrentIndex(1)
    dialog._start("download_version")
    wait_finished(qapp, dialog)
    assert downloaded == ["v1"]
    dialog._start("activate")
    assert dialog._task is None and not activated
    dialog._mode.setCurrentIndex(dialog._mode.findData("publisher"))
    dialog._start("activate")
    wait_finished(qapp, dialog)
    assert activated == ["v1"]
    assert dialog._versions.count() == 0
    assert all(not button.isEnabled() for button in dialog._version_actions)
    dialog._start("download_version")
    assert dialog._task is None
    assert "Select a cloud version" in dialog._status.text()


@pytest.mark.parametrize("language, titles", [
    ("en", {"Connection settings", "Template sync", "Template history"}),
    ("zh_CN", {"连接设置", "模板同步", "模板历史"}),
    ("ru", {"Настройки подключения", "Синхронизация шаблонов", "История шаблонов"}),
])
def test_template_only_layout(qapp, language, titles):
    set_language(language)
    dialog = make_dialog()
    assert {group.title() for group in dialog.findChildren(QGroupBox)} == titles
    assert dialog._test.parentWidget() is dialog._form
    assert dialog._save.parentWidget() is dialog._form
    assert len(dialog._actions) == 2
    assert not hasattr(dialog, "_configuration_path")
    assert not hasattr(dialog, "_history_kind")

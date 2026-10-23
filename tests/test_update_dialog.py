import os
import threading
import time
from collections.abc import Iterator

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

try:
    from PySide6.QtWidgets import QApplication
except ImportError as exc:
    pytest.skip(f"Qt system libraries not available: {exc}", allow_module_level=True)

from modbus_connector import __version__, main_window, update_dialog  # noqa: E402
from modbus_connector.i18n import set_language  # noqa: E402
from modbus_connector.main_window import MainWindow  # noqa: E402
from modbus_connector.update_check import RELEASES_URL, ReleaseInfo, UpdateCheckError  # noqa: E402
from modbus_connector.update_dialog import UpdateDialog  # noqa: E402


@pytest.fixture(scope="module")
def qapp() -> QApplication:
    return QApplication.instance() or QApplication([])


@pytest.fixture(autouse=True)
def cleanup(qapp: QApplication, monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    monkeypatch.setattr(main_window, "load_settings", lambda: {})
    monkeypatch.setattr(main_window, "save_settings", lambda state: None)
    monkeypatch.setattr(main_window, "apply_theme", lambda name: None)
    yield
    for widget in QApplication.topLevelWidgets():
        if isinstance(widget, (MainWindow, UpdateDialog)):
            widget.close()
            widget.deleteLater()
    qapp.processEvents()


def wait_finished(qapp: QApplication, dialog: UpdateDialog) -> None:
    deadline = time.monotonic() + 5
    while dialog._task is not None and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.005)
    assert dialog._task is None


@pytest.mark.parametrize(("release", "text", "download"), [
    (ReleaseInfo("v99.0.0", "<b>plain notes</b>"), "New version available: v99.0.0", True),
    (ReleaseInfo(f"v{__version__}", ""), "You are up to date.", False),
    (ReleaseInfo("v0.1.0", ""), "You are up to date.", False),
    (None, "No public stable release", False),
])
def test_results_and_explicit_browser_action(
    qapp: QApplication, monkeypatch: pytest.MonkeyPatch,
    release: ReleaseInfo | None, text: str, download: bool,
) -> None:
    monkeypatch.setattr(update_dialog, "check_for_update", lambda: release)
    opened = []
    monkeypatch.setattr(update_dialog.QDesktopServices, "openUrl",
                        lambda url: opened.append(url.toString()) or True)
    dialog = UpdateDialog()
    wait_finished(qapp, dialog)
    assert text in dialog._status.text()
    assert (dialog._download.text() == "Download update…") is download
    if release and release.notes:
        assert dialog._notes.toPlainText() == release.notes
    assert not opened
    dialog._download.click()
    assert opened == [release.url if release else RELEASES_URL]


def test_background_check_and_close_while_running(
    qapp: QApplication, monkeypatch: pytest.MonkeyPatch,
) -> None:
    entered = threading.Event()
    release = threading.Event()
    threads = []

    def check() -> None:
        threads.append(threading.get_ident())
        entered.set()
        assert release.wait(3)

    monkeypatch.setattr(update_dialog, "check_for_update", check)
    dialog = UpdateDialog()
    dialog.show()
    try:
        assert entered.wait(2)
        qapp.processEvents()
        assert not dialog._check.isEnabled()
        dialog._start()
        assert len(threads) == 1
        dialog.close()
        assert dialog.isVisible()
        assert "Finishing" in dialog._status.text()
    finally:
        release.set()
        wait_finished(qapp, dialog)
    assert len(threads) == 1
    assert threads[0] != threading.get_ident()
    assert not dialog.isVisible()


def test_localized_failure_and_retry(qapp: QApplication, monkeypatch: pytest.MonkeyPatch) -> None:
    def fail() -> None:
        raise UpdateCheckError("GitHub request failed: HTTP {status}.", status=503)

    monkeypatch.setattr(update_dialog, "check_for_update", fail)
    set_language("zh_CN")
    dialog = UpdateDialog()
    wait_finished(qapp, dialog)
    assert dialog._status.text() == "检查更新失败：GitHub 请求失败：HTTP 503。"
    monkeypatch.setattr(update_dialog, "check_for_update", lambda: ReleaseInfo("v99.0.0", "OK"))
    dialog._check.click()
    wait_finished(qapp, dialog)
    assert dialog._status.text().startswith("发现新版本：v99.0.0")


def test_retry_clears_previous_release(qapp: QApplication, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(update_dialog, "check_for_update", lambda: ReleaseInfo("v99.0.0", "OK"))
    dialog = UpdateDialog()
    wait_finished(qapp, dialog)
    monkeypatch.setattr(update_dialog, "check_for_update", lambda: None)
    dialog._check.click()
    wait_finished(qapp, dialog)
    assert dialog._release_url == RELEASES_URL
    assert dialog._notes.toPlainText() == ""
    assert dialog._download.text() == "Open releases page"


def test_browser_failure(qapp: QApplication, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(update_dialog, "check_for_update", lambda: None)
    monkeypatch.setattr(update_dialog.QDesktopServices, "openUrl", lambda url: False)
    dialog = UpdateDialog()
    wait_finished(qapp, dialog)
    dialog._download.click()
    assert dialog._status.text() == f"Could not open browser. Visit: {RELEASES_URL}"


def test_menu_action_and_language_switch(
    qapp: QApplication, monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls = []

    class Dialog:
        def __init__(self, parent: MainWindow) -> None:
            calls.append(parent)

        def exec(self) -> None:
            calls.append("exec")

        def deleteLater(self) -> None:
            pass

    monkeypatch.setattr(main_window, "UpdateDialog", Dialog)
    window = MainWindow()
    window._update_action.trigger()
    assert calls == [window, "exec"]
    set_language("zh_CN")
    assert window._help_menu.title() == "帮助"
    assert window._update_action.text() == "检查更新…"
    set_language("ru")
    assert window._update_action.text() == "Проверить обновления…"


@pytest.fixture
def installable(monkeypatch, tmp_path):
    from modbus_connector.update_check import ReleaseAsset

    release = ReleaseInfo('v99.0.0', 'New release', ReleaseAsset(
        'https://github.com/installer.exe', 100, 'a' * 64,
    ))
    monkeypatch.setattr(update_dialog, 'installed_executable',
                        lambda: tmp_path / 'ModbusConnector.exe')
    monkeypatch.setattr(update_dialog, 'check_for_update', lambda: release)
    monkeypatch.setattr(update_dialog.QMessageBox, 'question',
                        lambda *args: update_dialog.QMessageBox.StandardButton.Yes)
    return release


def wait_download(qapp, dialog):
    deadline = time.monotonic() + 5
    while dialog._download_task is not None and time.monotonic() < deadline:
        qapp.processEvents()
        time.sleep(0.005)
    assert dialog._download_task is None


def test_install_download_runs_in_background_and_hands_off(qapp, monkeypatch, installable):
    from types import SimpleNamespace

    handoff = SimpleNamespace(abort=lambda: None)
    thread_ids = []

    def prepare(asset, executable, cancel, progress):
        assert asset == installable.installer
        thread_ids.append(threading.get_ident())
        progress(100)
        return handoff

    monkeypatch.setattr(update_dialog, 'prepare_update', prepare)
    dialog = UpdateDialog()
    wait_finished(qapp, dialog)
    assert not dialog._install.isHidden()
    dialog._install.click()
    wait_download(qapp, dialog)
    assert len(thread_ids) == 1
    assert thread_ids[0] != threading.get_ident()
    assert dialog.result() == UpdateDialog.DialogCode.Accepted
    assert dialog.handoff is handoff
    assert dialog._progress.value() == 100


@pytest.mark.parametrize('late_success', [False, True])
def test_close_cancels_download_and_never_installs(qapp, monkeypatch, installable, late_success):
    from types import SimpleNamespace

    from modbus_connector.update_install import UpdateCancelled

    entered = threading.Event()
    aborted = []

    def prepare(asset, executable, cancel, progress):
        entered.set()
        assert cancel.wait(3)
        if late_success:
            return SimpleNamespace(abort=lambda: aborted.append(True))
        raise UpdateCancelled()

    monkeypatch.setattr(update_dialog, 'prepare_update', prepare)
    dialog = UpdateDialog()
    dialog.show()
    wait_finished(qapp, dialog)
    dialog._install.click()
    assert entered.wait(2)
    dialog.close()
    assert dialog.isVisible()
    wait_download(qapp, dialog)
    assert not dialog.isVisible()
    assert dialog.handoff is None
    assert dialog.result() == UpdateDialog.DialogCode.Rejected
    assert aborted == ([True] if late_success else [])


def test_download_failure_keeps_app_open_and_allows_retry(qapp, monkeypatch, installable):
    def fail(*args):
        raise UpdateCheckError('Installer verification failed. Please download again.')

    monkeypatch.setattr(update_dialog, 'prepare_update', fail)
    dialog = UpdateDialog()
    dialog.show()
    wait_finished(qapp, dialog)
    dialog._install.click()
    wait_download(qapp, dialog)
    assert dialog.isVisible()
    assert dialog.handoff is None
    assert 'verification failed' in dialog._status.text()
    assert dialog._install.isEnabled()
    assert dialog._check.isEnabled()


def test_declining_install_does_not_download(qapp, monkeypatch, installable):
    monkeypatch.setattr(update_dialog.QMessageBox, 'question',
                        lambda *args: update_dialog.QMessageBox.StandardButton.No)
    calls = []
    monkeypatch.setattr(update_dialog, 'prepare_update', lambda *args: calls.append(args))
    dialog = UpdateDialog()
    wait_finished(qapp, dialog)
    dialog._install.click()
    assert dialog._download_task is None
    assert calls == []


@pytest.mark.parametrize('failure', [None, 'save', 'commit'])
def test_update_exit_saves_before_handoff_and_shutdown(qapp, monkeypatch, failure):
    from types import SimpleNamespace

    from PySide6.QtGui import QCloseEvent

    calls = []
    window = MainWindow()
    original_shutdown = window._shutdown_sessions

    def save(state, *, strict=False):
        calls.append('save')
        assert strict
        if failure == 'save':
            raise OSError('disk full')

    def commit():
        calls.append('commit')
        if failure == 'commit':
            raise UpdateCheckError('The update helper stopped. Please try again.')

    monkeypatch.setattr(main_window, 'save_settings', save)
    monkeypatch.setattr(window, '_shutdown_sessions', lambda: calls.append('shutdown'))
    monkeypatch.setattr(main_window.QMessageBox, 'critical', lambda *args: calls.append('error'))
    window._update_handoff = SimpleNamespace(commit=commit, abort=lambda: calls.append('abort'))
    event = QCloseEvent()
    window.closeEvent(event)
    if failure:
        assert not event.isAccepted()
        assert 'shutdown' not in calls
        assert calls[-2:] == ['abort', 'error']
    else:
        assert event.isAccepted()
        assert calls == ['save', 'commit', 'shutdown']
    # Restore real shutdown and a tolerant saver for fixture cleanup.
    monkeypatch.setattr(window, '_shutdown_sessions', original_shutdown)
    monkeypatch.setattr(main_window, 'save_settings', lambda state: None)

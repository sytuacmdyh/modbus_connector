"""Background update checks with an explicit browser download action."""

from PySide6.QtCore import Qt, QThread, QUrl, Slot
from PySide6.QtGui import QCloseEvent, QDesktopServices
from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QLabel,
    QPlainTextEdit,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from modbus_connector import __version__
from modbus_connector.i18n import tr
from modbus_connector.update_check import (
    RELEASES_URL,
    ReleaseInfo,
    UpdateCheckError,
    check_for_update,
)


class _UpdateTask(QThread):
    def __init__(self, parent: QWidget) -> None:
        super().__init__(parent)
        self.result: ReleaseInfo | None = None
        self.error: Exception | None = None

    def run(self) -> None:
        try:
            self.result = check_for_update()
        except Exception as exc:
            self.error = exc


class UpdateDialog(QDialog):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle(tr("Check for updates"))
        self.resize(560, 380)
        self._task: _UpdateTask | None = None
        self._close_requested = False
        self._release_url = RELEASES_URL
        layout = QVBoxLayout(self)
        layout.addWidget(QLabel(tr("Current version: {version}", version=__version__)))
        self._status = QLabel()
        self._status.setTextFormat(Qt.TextFormat.PlainText)
        self._status.setWordWrap(True)
        layout.addWidget(self._status)
        self._notes = QPlainTextEdit()
        self._notes.setReadOnly(True)
        layout.addWidget(self._notes)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        buttons.rejected.connect(self.reject)
        self._check = QPushButton(tr("Check again"))
        self._check.clicked.connect(self._start)
        buttons.addButton(self._check, QDialogButtonBox.ButtonRole.ActionRole)
        self._download = QPushButton(tr("Open releases page"))
        self._download.clicked.connect(self._open_release)
        buttons.addButton(self._download, QDialogButtonBox.ButtonRole.ActionRole)
        layout.addWidget(buttons)
        self._start()

    @Slot()
    def _start(self) -> None:
        if self._task is not None:
            return
        self._release_url = RELEASES_URL
        self._download.setText(tr("Open releases page"))
        self._check.setEnabled(False)
        self._notes.clear()
        self._status.setText(tr("Checking for updates…"))
        self._task = _UpdateTask(self)
        self._task.finished.connect(self._finished)
        self._task.start()

    @Slot()
    def _finished(self) -> None:
        task = self._task
        self._task = None
        task.deleteLater()
        self._check.setEnabled(True)
        if self._close_requested:
            super().reject()
            return
        if task.error is not None:
            error = task.error
            detail = (tr(error.message_key, **error.params)
                      if isinstance(error, UpdateCheckError) else str(error))
            self._status.setText(tr("Update check failed: {detail}", detail=detail))
            return
        release = task.result
        if release is None:
            self._status.setText(tr(
                "No public stable release is available. Check the releases page."
            ))
            return
        self._release_url = release.url
        self._notes.setPlainText(release.notes or tr("No release notes."))
        if release.is_newer_than(__version__):
            self._status.setText(tr("New version available: {version}", version=release.tag))
            self._download.setText(tr("Download update…"))
        else:
            self._status.setText(tr("You are up to date. Latest release: {version}",
                                    version=release.tag))

    @Slot()
    def _open_release(self) -> None:
        if not QDesktopServices.openUrl(QUrl(self._release_url)):
            self._status.setText(tr("Could not open browser. Visit: {url}", url=self._release_url))

    def reject(self) -> None:
        if self._task is not None:
            self._close_requested = True
            self._status.setText(tr("Finishing update check…"))
            return
        super().reject()

    def closeEvent(self, event: QCloseEvent) -> None:
        if self._task is not None:
            self.reject()
            event.ignore()
            return
        super().closeEvent(event)

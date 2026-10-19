"""WebDAV setup and explicit synchronization actions."""

from collections.abc import Callable
from typing import Any

from PySide6.QtCore import QThread, Signal, Slot
from PySide6.QtGui import QCloseEvent
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)

from modbus_connector import templates
from modbus_connector.cloud_sync import CloudSyncError, WebDavClient, WebDavSettings
from modbus_connector.i18n import tr


class _CloudTask(QThread):
    def __init__(self, job: Callable[[Callable[[], bool]], object], parent: QWidget) -> None:
        super().__init__(parent)
        self.job = job
        self.result: object = None
        self.error: Exception | None = None

    def run(self) -> None:
        try:
            self.result = self.job(self.isInterruptionRequested)
        except Exception as exc:
            self.error = exc


class CloudSyncDialog(QDialog):
    templatesUpdated = Signal()

    def __init__(
        self, collect_state: Callable[[], dict[str, Any]],
        restore_state: Callable[[dict[str, Any]], None], parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle(tr("Cloud sync"))
        self.setMinimumWidth(580)
        self._collect_state = collect_state
        self._restore_state = restore_state
        self._task: _CloudTask | None = None
        self._close_requested = False
        self._operation = ""
        self._settings = WebDavSettings.load()
        self._mode = QComboBox()
        self._mode.addItem(tr("Consumer"), "consumer")
        self._mode.addItem(tr("Publisher"), "publisher")
        self._mode.setCurrentIndex(self._mode.findData(self._settings.mode))
        self._url = QLineEdit(self._settings.url)
        self._url.setPlaceholderText("https://dav.example.com/modbus-connector/")
        self._username = QLineEdit(self._settings.username)
        self._password = QLineEdit(self._settings.password)
        self._password.setEchoMode(QLineEdit.EchoMode.Password)
        self._templates_path = QLineEdit(self._settings.templates_path)
        self._configuration_path = QLineEdit(self._settings.configuration_path)
        self._timeout = QSpinBox(minimum=1, maximum=120, value=self._settings.timeout)
        self._remember = QCheckBox(tr("Remember password on this computer (plain text)"))
        self._remember.setChecked(self._settings.remember_password)
        self._form = QWidget()
        form = QFormLayout(self._form)
        form.setContentsMargins(0, 0, 0, 0)
        form.addRow(tr("Provider:"), QLabel("WebDAV"))
        form.addRow(tr("Mode:"), self._mode)
        form.addRow(tr("WebDAV folder URL:"), self._url)
        form.addRow(tr("Username:"), self._username)
        form.addRow(tr("Password:"), self._password)
        form.addRow(tr("Templates folder:"), self._templates_path)
        form.addRow(tr("Configuration file:"), self._configuration_path)
        form.addRow(tr("Timeout, s:"), self._timeout)
        form.addRow(self._remember)

        description = QLabel(tr(
            "Publishers can publish local templates and configurations with version history. "
            "Consumers only download. Account permissions are enforced by the WebDAV server."
        ))
        description.setWordWrap(True)
        self._status = QLabel()
        self._status.setWordWrap(True)
        self._actions: list[QPushButton] = []
        self._publisher_actions: list[QPushButton] = []
        actions = QHBoxLayout()
        for text, operation in (
            ("Test connection", "test"), ("Update templates", "templates"),
            ("Upload configuration", "upload"), ("Restore configuration", "restore"),
            ("Publish local templates", "publish"),
        ):
            button = QPushButton(tr(text))
            button.clicked.connect(lambda checked=False, op=operation: self._start(op))
            self._actions.append(button)
            if operation in ("upload", "publish"):
                self._publisher_actions.append(button)
            actions.addWidget(button)
        self._history_controls = QWidget()
        history = QHBoxLayout(self._history_controls)
        history.setContentsMargins(0, 0, 0, 0)
        history.addWidget(QLabel(tr("Version history:")))
        self._history_kind = QComboBox()
        self._history_kind.addItem(tr("Templates"), "templates")
        self._history_kind.addItem(tr("Configuration"), "configuration")
        self._versions = QComboBox()
        self._versions.setMinimumContentsLength(18)
        self._history_kind.currentIndexChanged.connect(self._versions.clear)
        for widget in (self._history_kind, self._versions):
            history.addWidget(widget)
        for label, operation in (("Load history", "history"),
                                 ("Download selected version", "download_version"),
                                 ("Set as current version", "activate")):
            button = QPushButton(tr(label))
            button.clicked.connect(lambda checked=False, op=operation: self._start(op))
            history.addWidget(button)
            if operation == "activate":
                self._publisher_actions.append(button)
        self._mode.currentIndexChanged.connect(self._update_mode)
        self._update_mode()
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        self._save = buttons.addButton(
            tr("Save connection"), QDialogButtonBox.ButtonRole.ActionRole,
        )
        self._save.clicked.connect(self._save_connection)
        buttons.rejected.connect(self.reject)
        layout = QVBoxLayout(self)
        layout.addWidget(self._form)
        layout.addWidget(description)
        layout.addLayout(actions)
        layout.addWidget(self._history_controls)
        layout.addWidget(self._status)
        layout.addWidget(buttons)

    def _update_mode(self) -> None:
        for button in self._publisher_actions:
            button.setVisible(self._mode.currentData() == "publisher")

    def _read_settings(self) -> WebDavSettings:
        return WebDavSettings(
            url=self._url.text().strip(), username=self._username.text(),
            password=self._password.text(), templates_path=self._templates_path.text().strip(),
            configuration_path=self._configuration_path.text().strip(),
            timeout=self._timeout.value(),
            remember_password=self._remember.isChecked(),
            mode=self._mode.currentData(),
        ).validated()

    def _show_error(self, error: Exception) -> None:
        detail = tr(error.key, **error.params) if isinstance(error, CloudSyncError) else str(error)
        self._status.setText(tr("Cloud sync failed: {detail}", detail=detail))

    @Slot()
    def _save_connection(self) -> None:
        try:
            settings = self._read_settings()
            settings.save()
            self._settings = settings
        except (CloudSyncError, OSError) as exc:
            self._show_error(exc)
            return
        self._status.setText(tr("Cloud connection saved."))

    def _start(self, operation: str) -> None:
        if self._task is not None:
            return
        try:
            settings = self._read_settings()
            if operation in ("upload", "publish", "activate") and settings.mode != "publisher":
                raise CloudSyncError("Consumer mode cannot publish or upload.")
            kind = self._history_kind.currentData()
            version = None
            if operation in ("download_version", "activate"):
                version = self._versions.currentData()
                if version is None:
                    raise CloudSyncError("Select a cloud version first.")
                if operation == "download_version":
                    operation = "templates" if kind == "templates" else "restore"
            catalog = None
            if operation == "publish":
                catalog = {info.resource: templates.load_template(info)
                           for info in templates.list_templates()}
                prompt = tr("Publish all {count} local templates as a new cloud version?",
                            count=len(catalog))
            elif operation == "activate":
                prompt = tr("Set the selected version as current for all users?")
            else:
                prompt = None
            if prompt and QMessageBox.question(
                self, tr("Cloud sync"), prompt,
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            ) != QMessageBox.StandardButton.Yes:
                return
            settings.save()
            self._settings = settings
            client = WebDavClient(settings)
            state = self._collect_state() if operation == "upload" else None
        except (CloudSyncError, OSError, ValueError) as exc:
            self._show_error(exc)
            return

        def job(cancelled: Callable[[], bool]) -> object:
            if operation == "test":
                return client.test_connection()
            if operation == "templates":
                return client.download_templates(cancelled=cancelled, version=version)
            if operation == "upload":
                return client.upload_configuration(state, cancelled=cancelled)
            if operation == "publish":
                return len(catalog), client.publish_templates(catalog, cancelled=cancelled)
            if operation == "history":
                return client.list_versions(kind)
            if operation == "activate":
                return client.activate_version(kind, version, cancelled=cancelled)
            if version is not None:
                return client.download_configuration(version=version)
            return client.download_configuration()

        self._operation = operation
        self._task = _CloudTask(job, self)
        self._task.finished.connect(self._finished)
        self._set_busy(True)
        self._status.setText(tr("Cloud operation in progress…"))
        self._task.start()

    def _set_busy(self, busy: bool) -> None:
        self._form.setEnabled(not busy)
        self._history_controls.setEnabled(not busy)
        self._save.setEnabled(not busy)
        for button in self._actions:
            button.setEnabled(not busy)

    @Slot()
    def _finished(self) -> None:
        task = self._task
        self._task = None
        self._set_busy(False)
        task.deleteLater()
        if self._close_requested:
            if self._operation == "templates" and task.error is None:
                self.templatesUpdated.emit()
            self._status.setText(tr("Cloud operation cancelled."))
            super().reject()
            return
        if task.error is not None:
            self._show_error(task.error)
            return
        if self._operation == "history":
            self._versions.clear()
            for version in task.result:
                self._versions.addItem(version, version)
            self._status.setText(tr("Loaded {count} cloud versions.", count=len(task.result)))
        elif self._operation == "publish":
            count, version = task.result
            self._versions.clear()
            self._status.setText(tr("Published {count} templates. Version: {version}",
                                    count=count, version=version))
        elif self._operation == "activate":
            self._versions.clear()
            self._status.setText(tr("Cloud version restored: {version}", version=task.result))
        elif self._operation == "templates":
            self.templatesUpdated.emit()
            self._status.setText(tr("Updated {count} cloud templates.", count=task.result))
        elif self._operation == "restore":
            answer = QMessageBox.question(
                self, tr("Restore configuration"),
                tr("Replace all current tabs with the cloud configuration? "
                   "Active connections will be closed."),
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if answer != QMessageBox.StandardButton.Yes:
                self._status.setText(tr("Cloud operation cancelled."))
                return
            try:
                self._restore_state(task.result)
            except Exception as exc:
                self._show_error(exc)
                return
            self._status.setText(tr("Cloud configuration restored."))
        elif self._operation == "upload":
            self._status.setText(tr("Configuration uploaded."))
        else:
            self._status.setText(tr("WebDAV connection successful."))

    def reject(self) -> None:
        if self._task is not None:
            self._close_requested = True
            self._task.requestInterruption()
            self._status.setText(tr("Cancelling cloud operation…"))
            return
        super().reject()

    def closeEvent(self, event: QCloseEvent) -> None:
        if self._task is not None:
            self.reject()
            event.ignore()
            return
        super().closeEvent(event)

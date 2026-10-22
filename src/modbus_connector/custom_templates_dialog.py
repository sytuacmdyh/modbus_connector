"""Manage local templates and open saved versions in disconnected tabs."""

from collections.abc import Callable
from datetime import datetime

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMessageBox,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from modbus_connector.custom_templates import CustomTemplateStore
from modbus_connector.i18n import tr


class CustomTemplatesDialog(QDialog):
    templatesChanged = Signal()
    openRequested = Signal(str, str)

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.store = CustomTemplateStore()
        self.setWindowTitle(tr("Manage custom templates"))
        self.resize(720, 420)
        layout = QVBoxLayout(self)
        layout.addWidget(QLabel(tr("Open a version, edit it, then save a new version.")))
        columns = QHBoxLayout()
        self.templates = QListWidget()
        self.versions = QListWidget()
        columns.addWidget(self.templates)
        columns.addWidget(self.versions)
        layout.addLayout(columns)
        buttons = QHBoxLayout()
        self._buttons: dict[str, QPushButton] = {}
        for label, callback in (
            ("Open version", self._open), ("Rename…", self._rename),
            ("Delete template…", self._delete), ("Delete version…", self._delete_version),
        ):
            button = QPushButton(tr(label))
            button.clicked.connect(callback)
            self._buttons[label] = button
            buttons.addWidget(button)
        layout.addLayout(buttons)
        close = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        close.rejected.connect(self.reject)
        layout.addWidget(close)
        self.templates.currentItemChanged.connect(self._load_versions)
        self.versions.currentItemChanged.connect(self._sync_buttons)
        self._reload()

    def _template_id(self) -> str | None:
        item = self.templates.currentItem()
        return item.data(Qt.ItemDataRole.UserRole) if item else None

    def _version_id(self) -> str | None:
        item = self.versions.currentItem()
        return item.data(Qt.ItemDataRole.UserRole) if item else None

    def _reload(self, selected: str | None = None) -> None:
        self.templates.clear()
        for info in self.store.list_templates():
            item = QListWidgetItem(info.name, self.templates)
            item.setData(Qt.ItemDataRole.UserRole, info.id)
            if info.id == selected:
                self.templates.setCurrentItem(item)
        if self.templates.currentRow() < 0:
            self.templates.setCurrentRow(0)
        self._sync_buttons()

    def _load_versions(self) -> None:
        self.versions.clear()
        template_id = self._template_id()
        if template_id:
            try:
                for version in self.store.versions(template_id):
                    saved = datetime.fromisoformat(version["saved_at"]).astimezone()
                    item = QListWidgetItem(
                        saved.strftime("%Y-%m-%d %H:%M:%S.%f %z"), self.versions,
                    )
                    item.setData(Qt.ItemDataRole.UserRole, version["id"])
                    item.setToolTip(version["id"])
            except (OSError, ValueError) as exc:
                self._error(exc)
        self.versions.setCurrentRow(0)
        self._sync_buttons()

    def _sync_buttons(self) -> None:
        for label in ("Rename…", "Delete template…"):
            self._buttons[label].setEnabled(self._template_id() is not None)
        self._buttons["Open version"].setEnabled(self._version_id() is not None)
        self._buttons["Delete version…"].setEnabled(
            self._version_id() is not None and self.versions.count() > 1,
        )

    def _error(self, exc: Exception) -> None:
        QMessageBox.warning(self, tr("Custom templates"), tr(str(exc)))

    def _change(self, operation: Callable[[], None]) -> None:
        selected = self._template_id()
        try:
            operation()
        except (OSError, ValueError) as exc:
            self._error(exc)
            return
        self._reload(selected)
        self.templatesChanged.emit()

    def _open(self) -> None:
        template_id, version_id = self._template_id(), self._version_id()
        if template_id and version_id:
            self.openRequested.emit(template_id, version_id)

    def _rename(self) -> None:
        template_id = self._template_id()
        if template_id:
            name, ok = QInputDialog.getText(
                self, tr("Rename…"), tr("Template name:"),
                text=self.templates.currentItem().text(),
            )
            if ok:
                self._change(lambda: self.store.rename(template_id, name))

    def _delete(self) -> None:
        template_id = self._template_id()
        if template_id and QMessageBox.question(
            self, tr("Delete template…"),
            tr("Delete this custom template and all its versions?"),
            defaultButton=QMessageBox.StandardButton.No,
        ) == QMessageBox.StandardButton.Yes:
            self._change(lambda: self.store.delete(template_id))

    def _delete_version(self) -> None:
        template_id, version_id = self._template_id(), self._version_id()
        if template_id and version_id and QMessageBox.question(
            self, tr("Delete version…"), tr("Delete this saved version?"),
            defaultButton=QMessageBox.StandardButton.No,
        ) == QMessageBox.StandardButton.Yes:
            self._change(lambda: self.store.delete_version(template_id, version_id))

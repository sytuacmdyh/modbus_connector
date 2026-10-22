"""Shared public/custom template menus for master and simulator."""

from collections.abc import Callable

from PySide6.QtWidgets import QMenu

from modbus_connector.custom_templates import CustomTemplateInfo, CustomTemplateStore
from modbus_connector.i18n import tr
from modbus_connector.templates import TemplateInfo, list_templates


def populate_template_menu(
    menu: QMenu, public_selected: Callable[[TemplateInfo], None],
    custom_selected: Callable[[CustomTemplateInfo], None],
) -> None:
    public = QMenu(tr("Public templates"), menu)
    custom = QMenu(tr("Custom templates"), menu)
    menu.addMenu(public)
    menu.addMenu(custom)
    manufacturers: dict[str, QMenu] = {}
    for info in list_templates():
        submenu = manufacturers.get(info.manufacturer)
        if submenu is None:
            submenu = QMenu(info.manufacturer, public)
            public.addMenu(submenu)
            manufacturers[info.manufacturer] = submenu
        action = submenu.addAction(info.name)
        action.setToolTip(info.description)
        action.triggered.connect(lambda checked=False, i=info: public_selected(i))
    for info in CustomTemplateStore().list_templates():
        action = custom.addAction(info.name)
        action.triggered.connect(lambda checked=False, i=info: custom_selected(i))
    for submenu in (public, custom):
        if not submenu.actions():
            submenu.addAction(tr("(empty)")).setEnabled(False)

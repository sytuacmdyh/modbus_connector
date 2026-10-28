import os
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from modbus_connector import templates  # noqa: E402
from modbus_connector.templates import (  # noqa: E402
    TemplateInfo,
    list_templates,
    load_template,
    parse_template,
)
from tests.template_fixtures import (  # noqa: E402
    FIXTURE_KEY,
    FIXTURE_RESOURCE,
    FIXTURE_TEMPLATE,
)


def test_list_templates_bundled_catalog_empty(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(templates, "CLOUD_TEMPLATES_PATH", tmp_path / "missing.json")
    assert list_templates() == []


def test_list_templates_includes_cloud_cache(cloud_template_cache: Path) -> None:
    del cloud_template_cache
    found = [t for t in list_templates() if t.resource == FIXTURE_RESOURCE]
    assert len(found) == 1
    info = found[0]
    assert info.manufacturer == "Acme"
    assert info.name == FIXTURE_TEMPLATE["name"]
    assert info.description


def test_list_templates_sorted_case_insensitive(cloud_template_catalog) -> None:
    del cloud_template_catalog
    keys = [(t.manufacturer.lower(), t.name.lower()) for t in list_templates()]
    assert keys == sorted(keys)


def test_load_template_by_info_and_key(cloud_template_cache) -> None:
    del cloud_template_cache
    info = next(t for t in list_templates() if t.resource == FIXTURE_RESOURCE)
    by_info = load_template(info)
    by_key = load_template(FIXTURE_KEY)
    assert by_info == by_key
    assert by_info["name"] == FIXTURE_TEMPLATE["name"]
    connection = by_info["connection"]
    assert connection["type"] == "RTU"
    assert connection["rtu_baud"] == "2400"
    assert connection["unit"] == 1
    registers = by_info["registers"]
    assert isinstance(registers, list) and len(registers) == len(FIXTURE_TEMPLATE["registers"])
    assert all(row["kind"] == "input_registers" for row in registers)


def test_load_template_unknown_key(cloud_template_cache) -> None:
    del cloud_template_cache
    with pytest.raises(ValueError, match="not found"):
        load_template("Acme/NoSuchDevice")


def test_parse_template_tolerates_broken_files(caplog: pytest.LogCaptureFixture) -> None:
    assert parse_template("{not json", "broken.json") is None
    assert parse_template('["not", "an", "object"]', "list.json") is None
    assert parse_template('{"connection": {}, "registers": []}', "noname.json") is None
    assert parse_template('{"name": "x", "registers": []}', "noconn.json") is None
    assert parse_template('{"name": "x", "connection": {}, "registers": {}}') is None
    assert "broken.json" in caplog.text


def test_template_info_defaults() -> None:
    info = TemplateInfo(name="n", manufacturer="m", resource="m/n.json")
    assert info.description == ""


# --- Qt round-trip: шаблон проходит через RegistersPanel.set_state ---

try:
    from PySide6.QtWidgets import QApplication  # noqa: E402
except ImportError as exc:
    pytest.skip(f"Qt system libraries not available: {exc}", allow_module_level=True)

from modbus_connector.registers_panel import RegistersPanel  # noqa: E402


@pytest.fixture(scope="module")
def qapp() -> QApplication:
    return QApplication.instance() or QApplication([])


def test_template_registers_roundtrip(qapp: QApplication, cloud_template_cache) -> None:
    del cloud_template_cache
    state = load_template(FIXTURE_KEY)
    panel = RegistersPanel(lambda: 1)
    try:
        panel.set_state(state["registers"])
        rows = panel.state()
        assert len(rows) == len(FIXTURE_TEMPLATE["registers"])
        voltage = rows[0]
        assert voltage["name"] == "Voltage"
        assert voltage["kind"] == "input_registers"
        assert voltage["address"] == 0
        assert voltage["count"] == 2
        assert voltage["format"] == "f32"
        assert voltage["unit"] == "V"
        assert rows[-2]["name"] == "Total active energy"
        assert rows[-2]["address"] == 342
        assert rows[-1]["name"] == "Total reactive energy"
        assert rows[-1]["address"] == 344
    finally:
        panel.deleteLater()


# (register row, адрес для поиска, bitmask, значение из value_names, ожидаемое имя)
ANNOTATED_ROWS = [
    (
        {
            "kind": "holding_registers",
            "address": 8194,
            "count": 1,
            "format": "dec",
            "bitmask": True,
            "value_names": {"1": "Reset", "10": "Run cmd via comm"},
        },
        8194,
        True,
        1,
        "Reset",
    ),
    (
        {
            "kind": "holding_registers",
            "address": 8448,
            "count": 1,
            "format": "dec",
            "bitmask": False,
            "value_names": {"17": "oH2"},
        },
        8448,
        False,
        17,
        "oH2",
    ),
    (
        {
            "kind": "holding_registers",
            "address": 12801,
            "count": 1,
            "format": "dec",
            "bitmask": True,
            "value_names": {"0": "Running"},
        },
        12801,
        True,
        0,
        "Running",
    ),
    (
        {
            "kind": "holding_registers",
            "address": 97,
            "count": 1,
            "format": "dec",
            "bitmask": False,
            "value_names": {"1": "AC voltage present"},
        },
        97,
        False,
        1,
        "AC voltage present",
    ),
    (
        {
            "kind": "holding_registers",
            "address": 5120,
            "count": 1,
            "format": "dec",
            "bitmask": False,
            "value_names": {"4096": ""},
        },
        5120,
        False,
        4096,
        None,
    ),
]


@pytest.mark.parametrize(
    ("register_row", "address", "bitmask", "value", "name"), ANNOTATED_ROWS
)
def test_template_annotations_roundtrip(
    qapp: QApplication,
    register_row: dict,
    address: int,
    bitmask: bool,
    value: int,
    name: str | None,
) -> None:
    """value_names/bitmask из шаблона переживают RegistersPanel set_state→state."""
    panel = RegistersPanel(lambda: 1)
    try:
        panel.set_state([register_row])
        rows = panel.state()
        row = next(r for r in rows if r["address"] == address)
        assert row["bitmask"] is bitmask
        names = row["value_names"]
        assert names, f"address {address}: empty value_names"
        if name is not None:
            assert names.get(str(value)) == name
    finally:
        panel.deleteLater()

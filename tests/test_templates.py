from pathlib import Path

import pytest

from modbus_connector import templates
from modbus_connector.templates import (
    TemplateInfo,
    list_templates,
    load_template,
    parse_template,
)
from tests.template_fixtures import (
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

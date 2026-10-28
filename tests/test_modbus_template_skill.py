"""The installed skill's validator must work without application dependencies."""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "skills/modbus-template/scripts/validate_template.py"
spec = importlib.util.spec_from_file_location("template_skill_validator", SCRIPT)
assert spec and spec.loader
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def template(**row_overrides):
    return {"name": "Test", "connection": {"type": "RTU", "unit": 1}, "registers": [
        {"name": "Temperature", "kind": "holding_registers", "address": 100,
         "count": 1, "format": "s16", "scale": 0.1, **row_overrides},
    ]}


@pytest.mark.parametrize("patch", [
    {"address": 65535, "count": 2},
    {"address": True},
    {"count": 1, "format": "f32"},
    {"count": 3, "format": "u32"},
    {"bitmask": True, "value_names": {"16": "Overflow"}},
    {"unit_id": 0},
    {"unit": 1},
    {"scale": float("nan")},
    {"order": "little"},
    {"kind": []},
])
def test_rejects_invalid_rows(patch):
    assert validator.validate(template(**patch))


def test_accepts_boundary_and_signed_enum():
    assert not validator.validate(template(address=65535, value_names={"-1": "Missing"}))
    assert not validator.validate(template(address=65534, count=2, format="f32", order="CDAB"))


def test_duplicate_keys_fail_in_standalone_cli(tmp_path):
    path = tmp_path / "duplicate.json"
    path.write_text('{"name":"first","name":"second"}', encoding="utf-8")
    result = subprocess.run([sys.executable, "-I", str(SCRIPT), str(path)],
                            capture_output=True, text=True)
    assert result.returncode == 1
    assert "duplicate JSON key" in result.stdout


def test_example_matches_application_loaders():
    from modbus_connector.flutter_catalog import flutter_state
    from modbus_connector.templates import parse_template

    reference = (SCRIPT.parent.parent / "references/template-format.md").read_text(encoding="utf-8")
    example = reference.split("```json\n", 1)[1].split("```", 1)[0]
    state = parse_template(example)
    assert state is not None
    assert not validator.validate(state)
    loaded = flutter_state(state)
    assert len(loaded["registers"]) == 3
    assert loaded["registers"][0]["scale"] == 0.1
    assert loaded["registers"][2]["value_names"]["3"] == "高压保护"


def test_bundled_public_templates_not_shipped():
    assert list((ROOT / "src/modbus_connector/templates").glob("*/*.json")) == []

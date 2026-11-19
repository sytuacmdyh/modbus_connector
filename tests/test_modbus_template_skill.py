"""The installed skill's validator must work without application dependencies."""

import importlib.util
import json
import shutil
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
    {"writable": "false"},
    {"writable": None},
    {"writable": 0},
    {"kind": "input_registers", "writable": True},
    {"kind": "discrete_inputs", "format": "u16", "writable": True},
])
def test_rejects_invalid_rows(patch):
    assert validator.validate(template(**patch))


def test_accepts_boundary_and_signed_enum():
    assert not validator.validate(template(address=65535, value_names={"-1": "Missing"}))
    assert not validator.validate(template(address=65534, count=2, format="f32", order="CDAB"))


@pytest.mark.parametrize("kind", ["holding_registers", "coils", "input_registers", "discrete_inputs"])
def test_read_only_access(kind):
    assert not validator.validate(template(kind=kind, format="u16", writable=False))
    if kind in ("holding_registers", "coils"):
        assert not validator.validate(template(kind=kind, format="u16", writable=True))


def test_accepts_canonical_u16_and_legacy_dec():
    assert not validator.validate(template(format="u16"))
    assert not validator.validate(template(format="dec"))


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
    assert not validator.validate(state, require_overview=True)
    loaded = flutter_state(state)
    assert len(loaded["registers"]) == 3
    assert loaded["registers"][0]["scale"] == 0.1
    assert loaded["registers"][2]["value_names"]["3"] == "高压保护"
    assert loaded["draft"]["map_overview"] == state["draft"]["map_overview"]
    assert [r["overview_id"] for r in loaded["registers"]] == [
        r["overview_id"] for r in state["registers"]
    ]


def test_installed_validator_checks_overview_without_application(tmp_path):
    installed = tmp_path / "installed" / "scripts"
    shutil.copytree(SCRIPT.parent, installed)
    data = template(overview_id="temperature")
    data["draft"] = {"map_overview": {"blocks": [
        {"name": "温度", "items": [{"row_id": "missing"}]},
    ]}}
    path = tmp_path / "overview.json"
    path.write_text(json.dumps(data), encoding="utf-8-sig")
    command = [sys.executable, "-I", str(installed / SCRIPT.name), "--require-overview", str(path)]
    rejected = subprocess.run(command, cwd=tmp_path, capture_output=True, text=True)
    assert rejected.returncode == 1
    assert "existing overview_id" in rejected.stdout
    data["draft"]["map_overview"]["blocks"][0]["items"][0]["row_id"] = "temperature"
    path.write_text(json.dumps(data), encoding="utf-8-sig")
    accepted = subprocess.run(command, cwd=tmp_path, capture_output=True, text=True)
    assert accepted.returncode == 0, accepted.stderr + accepted.stdout
    del data["draft"]["map_overview"]
    path.write_text(json.dumps(data), encoding="utf-8")
    missing = subprocess.run(command, cwd=tmp_path, capture_output=True, text=True)
    assert missing.returncode == 1
    assert "enabled, non-empty block" in missing.stdout


@pytest.mark.parametrize("overview", [None, {"blocks": []}, {"blocks": [
    {"name": "温度", "enabled": False, "items": [{"row_id": "temperature"}]},
]}, {"blocks": [{"name": "温度", "items": [{"row": 0}]}]}])
def test_generation_requires_active_overview_and_stable_references(overview):
    data = template(overview_id="temperature")
    if overview is not None:
        data["draft"] = {"map_overview": overview}
    assert validator.validate(data) == []  # Existing templates remain compatible.
    assert validator.validate(data, require_overview=True)


def test_generation_accepts_legacy_extension_with_stable_refs_without_invented_colors():
    data = template(overview_id="temperature")
    data["registers_options"] = {"flutter": {"draft": {"map_overview": {"blocks": [
        {"name": "温度", "items": [{"row_id": "temperature"}]},
    ]}}}}
    assert validator.validate(data, require_overview=True) == []


def test_bundled_public_templates_not_shipped():
    assert list((ROOT / "src/modbus_connector/templates").glob("*/*.json")) == []

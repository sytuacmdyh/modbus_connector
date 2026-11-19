"""Both independently installed skills accept the desktop presentation format."""

import copy
import runpy
from pathlib import Path

import pytest


@pytest.fixture(params=["modbus-template", "modbus-template-upload"])
def validate_presentation(request):
    script = (Path(__file__).resolve().parents[1] / "skills" / request.param
              / "scripts/template_presentation.py")
    return runpy.run_path(str(script))["validate_presentation"]


def overview(items, **fields):
    return {"registers": [{"overview_id": "temperature"}, {"overview_id": "state"}],
            "draft": {"map_overview": {"blocks": [
                {"name": "设备", "items": items, **fields},
            ]}}}


@pytest.mark.parametrize("data, message", [
    ({"registers": [{"overview_id": ""}]}, "non-empty"),
    ({"registers": [{"overview_id": 1}]}, "non-empty"),
    ({"registers": [{"overview_id": "a"}, {"overview_id": "a"}]}, "duplicated"),
    (overview([{"row_id": "missing"}]), "existing overview_id"),
    (overview([{"row": 2}]), "register index"),
    (overview([{"row": True}]), "register index"),
    (overview([{"row_id": "temperature", "row": 0}]), "exactly one"),
    (overview([{}]), "exactly one"),
    (overview([{"row_id": "temperature"}, {"row": 0}]), "duplicate register"),
    (overview([{"row": 0, "label": 7}]), "label"),
    (overview([], enabled="false"), "enabled"),
    (overview([], name=""), "name"),
    (overview(None), "items"),
    ({"draft": {"map_overview": {"blocks": {}}}}, "blocks"),
    ({"draft": {"map_split_ratio": True}}, "map_split_ratio"),
    ({"draft": {"map_split_ratio": .63}}, "map_split_ratio"),
    ({"draft": {"map_split_ratio": float("inf")}}, "map_split_ratio"),
    ({"registers_options": {"flutter": {"draft": []}}}, "draft"),
])
def test_invalid_structure_and_references(validate_presentation, data, message):
    assert any(message in error for error in validate_presentation(data))


@pytest.mark.parametrize("patch", [
    {"condition": "between"}, {"condition": []}, {"value": True},
    {"value": "60"}, {"value": float("nan")}, {"color": "green"},
    {"condition": "in_range"}, {"condition": "outside_range", "value2": "80"},
    {"value2": 80}, {"log": "true"}, {"sound": 1},
])
def test_invalid_rules(validate_presentation, patch):
    data = overview([{"row_id": "temperature", "rules": [
        {"condition": "ge", "value": 60, "color": "yellow", **patch},
    ]}])
    assert validate_presentation(data)


def test_valid_rules_order_legacy_and_preferences_remain_unchanged(validate_presentation):
    rules = [{"condition": condition, "value": 60, "color": color,
              **({"value2": 20} if condition.endswith("range") else {})}
             for condition in ("gt", "ge", "lt", "le", "eq", "ne", "in_range", "outside_range")
             for color in ("red", "yellow")]
    data = overview([{"row_id": "temperature", "rules": rules}, {"row": 1}])
    data["draft"]["map_split_ratio"] = .28
    data["draft"]["map_table"] = {"hidden": [], "density": "comfortable"}
    # Repeating a row across different blocks is intentional.
    data["draft"]["map_overview"]["blocks"].append(
        {"name": "状态", "enabled": False, "items": [{"row_id": "temperature", "rules": []}]},
    )
    original = copy.deepcopy(data)
    assert validate_presentation(data) == []
    assert data == original
    assert validate_presentation({"registers": [{}]}) == []
    assert validate_presentation({"draft": {"map_overview": {"blocks": []}}}) == []


def test_legacy_draft_shallow_override(validate_presentation):
    data = overview([{"row_id": "obsolete"}])
    data["draft"]["map_split_ratio"] = .9
    data["registers_options"] = {"flutter": {"draft": {
        "map_overview": {"blocks": []}, "map_split_ratio": .62,
    }}}
    assert validate_presentation(data) == []
    # An unrelated legacy draft field does not hide an invalid top-level overview.
    del data["registers_options"]["flutter"]["draft"]["map_overview"]
    assert any("existing overview_id" in error for error in validate_presentation(data))

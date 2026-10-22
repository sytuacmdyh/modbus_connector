import json
from datetime import datetime
from pathlib import Path

import pytest

from modbus_connector import custom_templates, templates
from modbus_connector.custom_templates import CustomTemplateStore


@pytest.fixture()
def store(tmp_path: Path) -> CustomTemplateStore:
    return CustomTemplateStore(tmp_path / "custom")


def state(value: int = 0) -> dict:
    return {
        "connection": {"unit": 1},
        "registers": [{"name": "Speed", "address": value, "kind": "holding_registers"}],
        "expressions": [{"name": "double", "expression": "[Speed] * 2"}],
    }


def test_each_save_keeps_an_independent_timestamped_snapshot(store):
    original = state(1)
    info = store.save(original, name="My pump")
    first = store.versions(info.id)[0]
    original["registers"][0]["address"] = 2
    store.save(original, template_id=info.id)
    store.save(original, template_id=info.id)  # even unchanged saves create a version
    versions = store.versions(info.id)
    assert len({v["id"] for v in versions}) == 3
    assert all(datetime.fromisoformat(v["saved_at"]).utcoffset().total_seconds() == 0
               for v in versions)
    assert store.load(info.id)["registers"][0]["address"] == 2
    assert store.load(info.id, first["id"])["registers"][0]["address"] == 1
    loaded = store.load(info.id)
    loaded["registers"].clear()
    assert store.load(info.id)["registers"]
    assert CustomTemplateStore(store.root).versions(info.id) == versions


def test_rename_delete_and_open_old_version_as_new(store):
    info = store.save(state(1), name="one")
    first = store.versions(info.id)[0]["id"]
    store.save(state(2), template_id=info.id)
    second = store.versions(info.id)[0]["id"]
    store.rename(info.id, "two / 中文")
    assert store.list_templates()[0].name == "two / 中文"
    assert store.load(info.id, first)["name"] == "two / 中文"
    store.save(store.load(info.id, first), template_id=info.id)
    latest = store.versions(info.id)[0]["id"]
    assert store.load(info.id)["registers"][0]["address"] == 1
    store.delete_version(info.id, latest)
    assert store.load(info.id)["registers"][0]["address"] == 2
    store.delete_version(info.id, first)
    with pytest.raises(ValueError, match="last version"):
        store.delete_version(info.id, second)
    store.delete(info.id)
    assert store.list_templates() == []


def test_failed_save_or_rename_preserves_all_versions(store, monkeypatch):
    info = store.save(state(), name="one")
    before = (store.root / f"{info.id}.json").read_bytes()
    with pytest.raises(ValueError):
        store.save({"connection": {}, "registers": [float("nan")]}, template_id=info.id)
    with pytest.raises(ValueError):
        store.rename(info.id, "   ")

    def fail(*args):
        raise OSError("disk full")

    monkeypatch.setattr("modbus_connector.cloud_sync.os.replace", fail)
    with pytest.raises(OSError):
        store.save(state(1), template_id=info.id)
    assert (store.root / f"{info.id}.json").read_bytes() == before
    assert len(list(store.root.iterdir())) == 1


def test_public_templates_are_isolated_from_user_edits(store, monkeypatch, tmp_path):
    cache = tmp_path / "cloud.json"
    monkeypatch.setattr(templates, "CLOUD_TEMPLATES_PATH", cache)
    monkeypatch.setattr(custom_templates, "CUSTOM_TEMPLATES_PATH", store.root)
    public = {"name": "Cloud device", **state(4)}
    cache.write_text(json.dumps({"Vendor/Test.json": public}))
    before = cache.read_bytes()
    info = store.save(templates.load_template("Vendor/Test"), name="Personal")
    store.save(state(9), template_id=info.id)
    store.rename(info.id, "My device")
    assert cache.read_bytes() == before
    assert all(t.name != "My device" for t in templates.list_templates())
    cache.write_text(json.dumps({"Vendor/Test.json": {"name": "New", **state(10)}}))
    assert store.load(info.id)["registers"][0]["address"] == 9
    assert templates.load_template("Vendor/Test")["registers"][0]["address"] == 10
    store.delete(info.id)
    assert templates.load_template("Vendor/Test")["name"] == "New"


@pytest.mark.parametrize("bad_id", ["../public", "Vendor/Test.json", "", "/tmp/file"])
def test_public_or_path_keys_cannot_be_written(store, bad_id):
    with pytest.raises(ValueError, match="ID"):
        store.save(state(), template_id=bad_id)
    with pytest.raises(ValueError, match="ID"):
        store.delete(bad_id)


def test_corrupt_files_are_skipped_but_never_overwritten(store):
    store.root.mkdir()
    template_id = "a" * 32
    path = store.root / f"{template_id}.json"
    path.write_text("broken")
    assert store.list_templates() == []
    with pytest.raises(ValueError):
        store.save(state(), template_id=template_id)
    assert path.read_text() == "broken"


def test_only_session_state_is_saved(store):
    info = store.save({**state(), "cloud": {"password": "secret"}, "password": "secret"},
                      name="Private")
    assert "secret" not in (store.root / f"{info.id}.json").read_text()

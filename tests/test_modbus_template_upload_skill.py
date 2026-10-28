import importlib.util
import json
from pathlib import Path

import pytest
from test_cloud_sync import TEMPLATE
from test_cloud_sync import dav_server as dav_server

from modbus_connector.cloud_sync import CloudSyncError, WebDavClient

SCRIPT = (Path(__file__).resolve().parents[1]
          / "skills/modbus-template-upload/scripts/upload_templates.py")
spec = importlib.util.spec_from_file_location("template_upload_skill", SCRIPT)
assert spec and spec.loader
uploader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uploader)


def test_manual_config_external_persistent_without_password(tmp_path, monkeypatch):
    monkeypatch.setenv("MODBUS_TEMPLATE_UPLOAD_HOME", str(tmp_path))
    monkeypatch.setenv("MODBUS_TEMPLATE_UPLOAD_PASSWORD", "not-saved")
    with pytest.raises(ValueError, match="Ask the user"):
        uploader.load_config()
    path = uploader.configure("https://example.invalid/dav/模板", "alice")
    stored = uploader.load_config()
    assert path == tmp_path / "config.json"
    assert stored == {"url": "https://example.invalid/dav/模板", "username": "alice", "timeout": 15}
    assert "not-saved" not in path.read_text()
    client = WebDavClient(uploader.settings(stored))
    assert client._url("模板/.catalog.json").endswith("/dav/%E6%A8%A1%E6%9D%BF/.catalog.json")


def test_reject_config_inside_skill_and_symlink(tmp_path, monkeypatch):
    skill = tmp_path / "skill"
    skill.mkdir()
    monkeypatch.setattr(uploader, "SKILL_DIR", skill)
    monkeypatch.setenv("MODBUS_TEMPLATE_UPLOAD_HOME", str(skill / "config"))
    with pytest.raises(ValueError, match="outside"):
        uploader.configure("https://example.invalid/templates")
    alias = tmp_path / "alias"
    try:
        alias.symlink_to(skill, target_is_directory=True)
    except OSError:
        pytest.skip("Directory symlinks unavailable")
    monkeypatch.setenv("MODBUS_TEMPLATE_UPLOAD_HOME", str(alias))
    with pytest.raises(ValueError, match="outside"):
        uploader.config_path()


@pytest.mark.parametrize("url", ["", "https://example.invalid/", "https://u:p@host/templates",
                               "https://host/templates?token=secret"])
def test_reject_invalid_endpoint(url):
    with pytest.raises((ValueError, CloudSyncError)):
        uploader.settings({"url": url})


def test_preview_merge_history_and_readback(dav_server):
    client = WebDavClient(dav_server.settings)
    old = {"厂家/旧设备.json": TEMPLATE, "厂家/保留.json": TEMPLATE}
    version = client.publish_templates(old)
    selected = {"厂家/旧设备.json": {**TEMPLATE, "name": "Updated"}, "厂家/新设备.json": TEMPLATE}
    before = len(dav_server.requests)
    preview = uploader.upload(client, selected, publish=False)
    assert preview["actions"] == {"厂家/旧设备.json": "replace", "厂家/新设备.json": "add"}
    assert all(method in ("GET", "PROPFIND") for method, _ in dav_server.requests[before:])
    result = uploader.upload(client, selected, publish=True)
    assert result["verified"]
    assert uploader.remote_templates(client) == {**old, **selected}
    assert version in client.list_versions()
    before = len(dav_server.requests)
    assert not uploader.upload(client, selected, publish=True)["published"]
    assert all(method == "GET" for method, _ in dav_server.requests[before:])


def test_preserves_legacy_templates(dav_server):
    dav_server.files["/dav/templates/厂家/旧设备.json"] = json.dumps(TEMPLATE).encode()
    client = WebDavClient(dav_server.settings)
    uploader.upload(client, {"厂家/新设备.json": TEMPLATE}, publish=True)
    assert set(uploader.remote_templates(client)) == {"厂家/旧设备.json", "厂家/新设备.json"}


def test_new_directory_and_failed_publish_preserves_active_catalog(dav_server):
    dav_server.directories.remove("/dav/templates/厂家/")
    dav_server.directories.remove("/dav/templates/")
    client = WebDavClient(dav_server.settings)
    uploader.upload(client, {"厂家/新设备.json": TEMPLATE}, publish=True)
    original = dav_server.files["/dav/templates/.catalog.json"]
    dav_server.fail_path = "/dav/templates/.catalog.json"
    with pytest.raises(CloudSyncError):
        uploader.upload(client, {"厂家/另一个.json": TEMPLATE}, publish=True)
    assert dav_server.files["/dav/templates/.catalog.json"] == original


def test_corrupt_remote_or_redirect_never_writes(dav_server):
    client = WebDavClient(dav_server.settings)
    dav_server.files["/dav/templates/.catalog.json"] = b"broken"
    with pytest.raises(CloudSyncError):
        uploader.upload(client, {"厂家/新设备.json": TEMPLATE}, publish=True)
    dav_server.redirect = True
    with pytest.raises(CloudSyncError):
        uploader.upload(client, {"厂家/新设备.json": TEMPLATE}, publish=True)
    assert all(method == "GET" for method, _ in dav_server.requests)


def test_local_resource_validation(tmp_path):
    path = tmp_path / "template.json"
    path.write_text(json.dumps(TEMPLATE), encoding="utf-8")
    assert uploader.local_templates([path], "厂家/设备.json") == {"厂家/设备.json": TEMPLATE}
    with pytest.raises(CloudSyncError):
        uploader.local_templates([path], "../设备.json")

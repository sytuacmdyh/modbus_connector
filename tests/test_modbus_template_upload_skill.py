import copy
import importlib.util
import json
import os
import shutil
import subprocess
import sys
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
    assert "not-saved" not in path.read_text(encoding="utf-8")
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


def test_password_opt_in_resolution_and_redacted_output(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("MODBUS_TEMPLATE_UPLOAD_HOME", str(tmp_path))
    monkeypatch.delenv("MODBUS_TEMPLATE_UPLOAD_PASSWORD", raising=False)
    path = uploader.configure("https://example.invalid/templates", "admin", password="test-secret")
    config = uploader.load_config()
    assert uploader.password_for(config) == "test-secret"
    if os.name != "nt":
        assert path.stat().st_mode & 0o777 == 0o600
    monkeypatch.setattr(sys, "argv", [str(SCRIPT), "config-show"])
    assert uploader.main() == 0
    output = capsys.readouterr().out
    assert "test-secret" not in output
    assert json.loads(output)["password_saved"] is True
    monkeypatch.setenv("MODBUS_TEMPLATE_UPLOAD_PASSWORD", "override-secret")
    assert uploader.password_for(config) == "override-secret"
    uploader.configure("https://example.invalid/templates", "other-user")
    assert "password" not in uploader.load_config()


def test_cli_password_save_requires_opt_in(tmp_path, monkeypatch):
    monkeypatch.setenv("MODBUS_TEMPLATE_UPLOAD_HOME", str(tmp_path))
    monkeypatch.setenv("MODBUS_TEMPLATE_UPLOAD_PASSWORD", "test-secret")
    args = [str(SCRIPT), "configure", "--url", "https://example.invalid/templates",
            "--username", "admin"]
    monkeypatch.setattr(sys, "argv", args)
    assert uploader.main() == 0
    assert "password" not in uploader.load_config()
    monkeypatch.setattr(sys, "argv", [*args, "--remember-password"])
    assert uploader.main() == 0
    assert uploader.load_config()["password"] == "test-secret"


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


def presentation_template():
    return {**TEMPLATE, "registers": [{"name": "温度", "overview_id": "temperature"}],
            "draft": {"map_split_ratio": .42, "map_overview": {"blocks": [
                {"name": "温度", "enabled": True, "items": [
                    {"row_id": "temperature", "rules": [
                        {"condition": "ge", "value": 80, "color": "red"},
                        {"condition": "in_range", "value": 60, "value2": 80, "color": "yellow"},
                    ]},
                ]},
                {"name": "重复展示", "items": [{"row_id": "temperature", "rules": []}]},
            ]}}}


def test_invalid_overview_rejected_before_any_remote_io(tmp_path, dav_server):
    data = presentation_template()
    data["draft"]["map_overview"]["blocks"][0]["items"][0]["row_id"] = "missing"
    path = tmp_path / "template.json"
    path.write_text(json.dumps(data), encoding="utf-8-sig")
    with pytest.raises(ValueError, match="existing overview_id"):
        uploader.local_templates([path], "厂家/设备.json")
    for publish in (False, True):
        with pytest.raises(ValueError, match="existing overview_id"):
            uploader.upload(WebDavClient(dav_server.settings), {"厂家/设备.json": data},
                            publish=publish)
    assert dav_server.requests == []


def test_duplicate_keys_rejected_on_upload(tmp_path):
    path = tmp_path / "duplicate.json"
    path.write_text('{"name":"first","name":"second"}', encoding="utf-8")
    with pytest.raises(ValueError, match="duplicate JSON key"):
        uploader.local_templates([path], "厂家/设备.json")


def test_installed_upload_cli_checks_local_data_before_network(tmp_path, dav_server, monkeypatch):
    installed = tmp_path / "installed" / "scripts"
    shutil.copytree(SCRIPT.parent, installed)
    config_dir = tmp_path / "config"
    monkeypatch.setenv("MODBUS_TEMPLATE_UPLOAD_HOME", str(config_dir))
    uploader.configure(dav_server.settings.url + "/templates")
    data = presentation_template()
    data["draft"]["map_overview"]["blocks"][0]["items"][0]["rules"][0]["color"] = "green"
    path = tmp_path / "template.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    result = subprocess.run(
        [sys.executable, "-I", str(installed / SCRIPT.name), "upload", str(path),
         "--resource", "厂家/设备.json", "--publish"],
        # Keep OS runtime variables (notably USERPROFILE/SystemRoot on Windows).
        # -I already isolates Python imports from the environment and cwd.
        cwd=tmp_path, env={**os.environ, "MODBUS_TEMPLATE_UPLOAD_HOME": str(config_dir)},
        capture_output=True, text=True,
    )
    assert result.returncode == 1
    assert "color must be red or yellow" in result.stderr
    assert dav_server.requests == []


def test_overview_only_update_preserves_full_json_history_and_other_templates(tmp_path, dav_server):
    client = WebDavClient(dav_server.settings)
    data = presentation_template()
    resource = "厂家/设备.json"
    # A newly stricter presentation check must not reject or rewrite unrelated remote data.
    other = {**TEMPLATE, "draft": {"map_overview": {"blocks": "legacy-invalid"}}}
    version = client.publish_templates({resource: data, "厂家/保留.json": other})
    changed = copy.deepcopy(data)
    changed["draft"]["map_overview"]["blocks"].reverse()
    changed["draft"]["map_overview"]["blocks"][1]["items"][0]["rules"][0]["value"] = 90
    path = tmp_path / "template.json"
    path.write_text(json.dumps(changed), encoding="utf-8-sig")
    selected = uploader.local_templates([path], resource)
    before = len(dav_server.requests)
    preview = uploader.upload(client, selected, publish=False)
    assert preview["actions"] == {resource: "replace"}
    assert preview["warnings"] == {}
    assert preview["overview"][resource] == {
        "status": "configured", "blocks": 2, "items": 2, "active_items": 2,
        "color_rules": 2, "legacy_references": 0,
    }
    assert all(method == "GET" for method, _ in dav_server.requests[before:])
    result = uploader.upload(client, selected, publish=True)
    assert result["published"] and result["verified"]
    assert uploader.remote_templates(client) == {resource: changed, "厂家/保留.json": other}
    history = json.loads(dav_server.files[f"/dav/templates/.versions/{version}.json"])
    assert history["templates"][resource] == data
    current = json.loads(dav_server.files[
        f"/dav/templates/.versions/{result['version']}.json"
    ])
    assert current["templates"][resource] == changed
    before = len(dav_server.requests)
    assert not uploader.upload(client, selected, publish=True)["published"]
    assert all(method == "GET" for method, _ in dav_server.requests[before:])


@pytest.mark.parametrize("draft, status, warning", [
    ({}, "missing", "缺少概览"),
    ({"map_overview": {"blocks": []}}, "empty", "没有启用"),
    ({"map_overview": {"blocks": [
        {"name": "温度", "enabled": False, "items": [{"row_id": "temperature"}]},
    ]}}, "empty", "没有启用"),
    ({"map_overview": {"blocks": [
        {"name": "温度", "items": [{"row": 0}]},
    ]}}, "configured", "旧式行下标"),
])
def test_preview_reports_incomplete_overview_without_rewriting(dav_server, draft, status, warning):
    data = presentation_template()
    data["draft"] = draft
    selected = {"厂家/设备.json": data}
    original = copy.deepcopy(selected)
    result = uploader.upload(WebDavClient(dav_server.settings), selected, publish=False)
    assert result["overview"]["厂家/设备.json"]["status"] == status
    assert any(warning in message for message in result["warnings"]["厂家/设备.json"])
    assert selected == original
    assert not result["published"]
    assert all(method in ("GET", "PROPFIND") for method, _ in dav_server.requests)


def test_preview_respects_legacy_override_and_does_not_demand_color_thresholds(dav_server):
    data = presentation_template()
    data["draft"] = {"map_overview": {"blocks": []}}
    data["registers_options"] = {"flutter": {"draft": {"map_overview": {"blocks": [
        {"name": "温度", "items": [{"row_id": "temperature", "rules": []}]},
    ]}}}}
    result = uploader.upload(WebDavClient(dav_server.settings), {"厂家/设备.json": data},
                             publish=False)
    assert result["warnings"] == {}
    assert result["overview"]["厂家/设备.json"]["status"] == "configured"
    assert result["overview"]["厂家/设备.json"]["color_rules"] == 0

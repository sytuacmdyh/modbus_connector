import json
import threading
import time
from dataclasses import asdict

from test_cloud_sync import dav_server as dav_server

from modbus_connector.flutter_bridge import Bridge
from modbus_connector.update_check import ReleaseInfo


def request(bridge, command, **data):
    return bridge.respond({"id": 1, "command": command, **data})


def finish(bridge):
    deadline = time.monotonic() + 5
    while True:
        status = request(bridge, "cloud_status")["result"]
        if not status["running"]:
            return status
        assert time.monotonic() < deadline
        time.sleep(0.01)


def test_real_webdav_publication_history_and_isolated_cache(dav_server, tmp_path, monkeypatch):
    monkeypatch.setenv("MODBUS_FLUTTER_HOME", str(tmp_path))
    bridge = Bridge()
    settings = asdict(dav_server.settings)
    try:
        assert request(bridge, "cloud_settings_save", settings=settings)["ok"]
        assert "password" not in json.loads((tmp_path / "cloud.json").read_text())
        assert request(bridge, "cloud_start", action="publish", settings=settings)["ok"]
        published = finish(bridge)
        assert not published["error"]
        version = published["result"]["version"]
        settings["mode"] = "consumer"
        before = len(dav_server.requests)
        assert not request(
            bridge, "cloud_start", action="activate", version=version, settings=settings
        )["ok"]
        assert len(dav_server.requests) == before
        assert request(bridge, "cloud_start", action="versions", settings=settings)["ok"]
        assert version in finish(bridge)["result"]["versions"]
        assert request(
            bridge, "cloud_start", action="download", version=version, settings=settings
        )["ok"]
        assert finish(bridge)["result"]["downloaded"] > 0
        assert (tmp_path / "cloud_templates.json").is_file()
        assert request(bridge, "template_list")["result"]["public"]
    finally:
        bridge.close()


def test_cloud_cancellation_and_update_surface(tmp_path, monkeypatch):
    monkeypatch.setenv("MODBUS_FLUTTER_HOME", str(tmp_path))
    from modbus_connector import flutter_online

    entered = threading.Event()
    release = threading.Event()

    def delayed(_self, **kwargs):
        entered.set()
        assert release.wait(3)
        assert kwargs["cancelled"]()
        raise ValueError("cancelled at network boundary")

    monkeypatch.setattr(flutter_online.WebDavClient, "download_templates", delayed)
    bridge = Bridge()
    try:
        assert request(
            bridge, "cloud_start", action="download", settings={"url": "https://example.invalid"}
        )["ok"]
        assert entered.wait(2)
        assert request(bridge, "cloud_cancel")["ok"]
        release.set()
        assert "cancelled" in finish(bridge)["error"]
        monkeypatch.setattr(
            flutter_online, "check_for_update", lambda: ReleaseInfo("v99.0.0", "Plain notes")
        )
        result = request(bridge, "update_check")["result"]
        assert result["newer"] and not result["install_supported"]
        assert result["release"]["notes"] == "Plain notes"
        assert "Flutter-specific" in result["install_reason"]
        assert not request(bridge, "update_install")["ok"]
    finally:
        release.set()
        bridge.close()

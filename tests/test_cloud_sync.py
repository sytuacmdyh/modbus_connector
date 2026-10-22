import base64
import json
import threading
import xml.etree.ElementTree as ET
from collections.abc import Iterator
from dataclasses import replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import quote, unquote

import pytest

from modbus_connector import cloud_sync, templates
from modbus_connector.cloud_sync import (
    CloudSyncError,
    WebDavClient,
    WebDavSettings,
    atomic_json,
)

TEMPLATE = {"name": "Cloud device", "connection": {"type": "RTU"}, "registers": []}


@pytest.fixture()
def dav_server() -> Iterator[SimpleNamespace]:
    files: dict[str, bytes] = {}
    directories = {"/dav/", "/dav/templates/", "/dav/templates/厂家/"}
    requests: list[tuple[str, str]] = []
    server_state = SimpleNamespace(files=files, directories=directories, requests=requests,
                                   listing=None, redirect=False, fail_path=None)
    auth = "Basic " + base64.b64encode(b"alice:secret").decode()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args: object) -> None:
            pass

        def reply(self, code: int, body: bytes = b"") -> None:
            self.send_response(code)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def dispatch(self) -> None:
            path = unquote(self.path)
            requests.append((self.command, path))
            payload = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if self.headers.get("Authorization") != auth:
                self.reply(401)
                return
            if self.command == "PUT" and path == server_state.fail_path:
                self.reply(507)
                return
            if server_state.redirect:
                self.send_response(302)
                self.send_header("Location", "/stolen/")
                self.end_headers()
                return
            if self.command == "PROPFIND":
                if path not in directories:
                    self.reply(404)
                    return
                if server_state.listing is not None:
                    self.reply(207, server_state.listing)
                    return
                assert ET.fromstring(payload).tag == "{DAV:}propfind"
                children = [path]
                if self.headers["Depth"] == "1":
                    children += sorted(p for p in directories | files.keys()
                                       if p != path and p.startswith(path)
                                       and "/" not in p[len(path):].rstrip("/"))
                root = ET.Element("{DAV:}multistatus")
                for child in children:
                    response = ET.SubElement(root, "{DAV:}response")
                    ET.SubElement(response, "{DAV:}href").text = quote(child)
                    propstat = ET.SubElement(response, "{DAV:}propstat")
                    ET.SubElement(propstat, "{DAV:}status").text = "HTTP/1.1 200 OK"
                    prop = ET.SubElement(propstat, "{DAV:}prop")
                    resource_type = ET.SubElement(prop, "{DAV:}resourcetype")
                    if child in directories:
                        ET.SubElement(resource_type, "{DAV:}collection")
                self.reply(207, ET.tostring(root))
            elif self.command == "GET":
                self.reply(200, files[path]) if path in files else self.reply(404)
            elif self.command == "MKCOL":
                if path in directories:
                    self.reply(405)
                elif path.rstrip("/").rsplit("/", 1)[0] + "/" not in directories:
                    self.reply(409)
                else:
                    directories.add(path)
                    self.reply(201)
            elif self.command == "PUT":
                if path.rsplit("/", 1)[0] + "/" not in directories:
                    self.reply(409)
                else:
                    files[path] = payload
                    self.reply(204)

        do_PROPFIND = dispatch
        do_GET = dispatch
        do_PUT = dispatch
        do_MKCOL = dispatch

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    server_state.settings = WebDavSettings(
        url=f"http://127.0.0.1:{server.server_port}/dav", username="alice", password="secret",
        mode="publisher",
    )
    yield server_state
    server.shutdown()
    server.server_close()
    thread.join(timeout=3)


def test_templates_overlay_cache_and_refresh(
    dav_server: SimpleNamespace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    cache = tmp_path / "cloud_templates.json"
    monkeypatch.setattr(templates, "CLOUD_TEMPLATES_PATH", cache)
    dav_server.directories.add("/dav/templates/Eastron/")
    dav_server.files["/dav/templates/厂家/设备.json"] = json.dumps(TEMPLATE).encode()
    dav_server.files["/dav/templates/Eastron/SDM120.json"] = json.dumps(
        {**TEMPLATE, "name": "Updated SDM120"},
    ).encode()
    dav_server.files["/dav/templates/厂家/readme.txt"] = b"ignored"
    client = WebDavClient(dav_server.settings)
    assert client.download_templates() == 2
    assert templates.load_template("厂家/设备") == TEMPLATE
    assert templates.load_template("Eastron/SDM120")["name"] == "Updated SDM120"
    catalog = templates.list_templates()
    assert len([t for t in catalog if t.resource == "Eastron/SDM120.json"]) == 1
    assert any(t.name == "Cloud device" for t in catalog)
    # Remote removal drops the overlay, exposing the bundled template again.
    dav_server.files.clear()
    assert client.download_templates() == 0
    assert templates.load_template("Eastron/SDM120")["name"] == "Eastron SDM120"


def test_failed_or_cancelled_templates_preserve_cache(
    dav_server: SimpleNamespace, tmp_path: Path,
) -> None:
    cache = tmp_path / "cache.json"
    atomic_json(cache, {"old": "preserved"})
    before = cache.read_bytes()
    client = WebDavClient(dav_server.settings)
    dav_server.files["/dav/templates/厂家/a.json"] = json.dumps(TEMPLATE).encode()
    dav_server.files["/dav/templates/厂家/z.json"] = b"{broken"
    with pytest.raises(CloudSyncError, match="Invalid cloud template"):
        client.download_templates(cache_path=cache)
    assert cache.read_bytes() == before
    with pytest.raises(CloudSyncError, match="cancelled"):
        client.download_templates(cache_path=cache, cancelled=lambda: True)
    assert cache.read_bytes() == before
    dav_server.directories.remove("/dav/templates/")
    with pytest.raises(CloudSyncError, match="404"):
        client.download_templates(cache_path=cache)
    assert cache.read_bytes() == before


def test_authentication_and_redirects(dav_server: SimpleNamespace) -> None:
    with pytest.raises(CloudSyncError, match="401") as error:
        WebDavClient(replace(dav_server.settings, password="wrong-secret")).test_connection()
    assert "wrong-secret" not in str(error.value)
    dav_server.redirect = True
    with pytest.raises(CloudSyncError, match="302"):
        WebDavClient(dav_server.settings).test_connection()
    assert all(path != "/stolen/" for _, path in dav_server.requests)


@pytest.mark.parametrize("href", ["http://other.example/templates/", "/outside/",
                                  "/dav/templates/%2e%2e/", "/dav/templates/a%2fb/", ""])
def test_reject_unsafe_directory_hrefs(dav_server: SimpleNamespace, href: str) -> None:
    root = ET.Element("{DAV:}multistatus")
    response = ET.SubElement(root, "{DAV:}response")
    ET.SubElement(response, "{DAV:}href").text = href
    dav_server.listing = ET.tostring(root)
    with pytest.raises(CloudSyncError, match="directory response"):
        WebDavClient(dav_server.settings).download_templates()
    assert not any(method == "GET" and path != "/dav/templates/.catalog.json"
                   for method, path in dav_server.requests)


@pytest.mark.parametrize("body", [b"<html>login</html>", b"invalid xml",
                                  b'<d:multistatus xmlns:d="DAV:"/>'])
def test_reject_invalid_listing(dav_server: SimpleNamespace, body: bytes) -> None:
    dav_server.listing = body
    with pytest.raises(CloudSyncError, match="directory response"):
        WebDavClient(dav_server.settings).test_connection()


@pytest.mark.parametrize("url", ["file:///tmp/dav", "ftp://host", "https://a:b@host/",
                                 "https://host/?token=secret", "https://host/#fragment",
                                 "https://host/%2e%2e/dav", "https://host:bad/", ""])
def test_reject_invalid_url(url: str) -> None:
    with pytest.raises(CloudSyncError):
        WebDavSettings(url=url).validated()


@pytest.mark.parametrize("path", ["../settings.json", "/settings.json", "a//b", "a/./b",
                                  "a\\b", "https://other/x", "a?query", ""])
def test_reject_invalid_relative_paths(path: str) -> None:
    with pytest.raises(CloudSyncError):
        WebDavSettings(url="https://example.com", templates_path=path).validated()


def test_credentials_are_local_and_opt_in(tmp_path: Path) -> None:
    path = tmp_path / "cloud.json"
    settings = WebDavSettings(url="https://example.com/dav/", username="a", password="secret")
    settings.save(path)
    assert "secret" not in path.read_text(encoding="utf-8")
    assert WebDavSettings.load(path).password == ""
    replace(settings, remember_password=True).save(path)
    assert WebDavSettings.load(path).password == "secret"
    settings.save(path)
    assert "secret" not in path.read_text(encoding="utf-8")
    assert "secret" not in repr(settings)


def test_atomic_cache_failure_keeps_previous_file(tmp_path: Path) -> None:
    path = tmp_path / "cache.json"
    atomic_json(path, {"old": True})
    with pytest.raises(ValueError):
        atomic_json(path, {"bad": float("nan")})
    assert json.loads(path.read_text(encoding="utf-8")) == {"old": True}
    assert list(tmp_path.iterdir()) == [path]


def test_response_size_limit(
    dav_server: SimpleNamespace, monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(cloud_sync, "MAX_RESPONSE_BYTES", 5)
    dav_server.files["/dav/templates/.catalog.json"] = b"123456"
    with pytest.raises(CloudSyncError, match="limit"):
        WebDavClient(dav_server.settings).download_templates()


def test_mode_is_local_defaults_to_consumer_and_persists(tmp_path: Path):
    path = tmp_path / "cloud.json"
    assert WebDavSettings.load(path).mode == "consumer"
    settings = WebDavSettings(url="https://example.com/", mode="publisher")
    settings.save(path)
    assert WebDavSettings.load(path).mode == "publisher"
    atomic_json(path, {"mode": "invalid", "remember_password": True})
    assert WebDavSettings.load(path).mode == "consumer"
    assert WebDavSettings.load(path).password == ""
    with pytest.raises(CloudSyncError, match="mode"):
        replace(settings, mode="invalid").validated()


@pytest.mark.parametrize("operation", ["templates", "activate", "PUT", "MKCOL"])
def test_consumer_blocks_all_writes_before_network(dav_server, operation):
    client = WebDavClient(replace(dav_server.settings, mode="consumer"))
    with pytest.raises(CloudSyncError, match="Consumer mode"):
        if operation == "templates":
            client.publish_templates({"厂家/a.json": TEMPLATE})
        elif operation == "activate":
            client.activate_version("invalid")
        else:
            client._request(operation, "templates/.catalog.json", body=b"{}")
    assert dav_server.requests == []


def test_template_publication_history_consumer_download_and_rollback(dav_server, tmp_path):
    publisher = WebDavClient(dav_server.settings)
    consumer = WebDavClient(replace(dav_server.settings, mode="consumer"))
    first = {"厂家/设备.json": TEMPLATE}
    second = {"厂家/设备.json": {**TEMPLATE, "name": "Version 2"}}
    v1 = publisher.publish_templates(first)
    v2 = publisher.publish_templates(second)
    assert consumer.list_versions() == sorted([v1, v2], reverse=True)
    cache = tmp_path / "cache.json"
    consumer.download_templates(cache_path=cache)
    assert json.loads(cache.read_text(encoding="utf-8")) == second
    consumer.download_templates(cache_path=cache, version=v1)
    assert json.loads(cache.read_text(encoding="utf-8")) == first
    v3 = publisher.activate_version(v1)
    consumer.download_templates(cache_path=cache)
    assert json.loads(cache.read_text(encoding="utf-8")) == first
    assert len(consumer.list_versions()) == 3
    assert v3 not in (v1, v2)
    archived = json.loads(dav_server.files[f"/dav/templates/.versions/{v2}.json"])
    assert archived["templates"] == second


def test_failed_and_cancelled_publish_preserve_current_release(dav_server):
    client = WebDavClient(dav_server.settings)
    first = {"厂家/a.json": TEMPLATE}
    client.publish_templates(first)
    current = dav_server.files["/dav/templates/.catalog.json"]
    dav_server.fail_path = "/dav/templates/.catalog.json"
    with pytest.raises(CloudSyncError, match="507"):
        client.publish_templates({"厂家/b.json": TEMPLATE})
    assert dav_server.files["/dav/templates/.catalog.json"] == current
    dav_server.fail_path = None
    with pytest.raises(CloudSyncError, match="cancelled"):
        client.publish_templates(first, cancelled=lambda: True)
    assert dav_server.files["/dav/templates/.catalog.json"] == current
    checks = iter([False, True])
    with pytest.raises(CloudSyncError, match="cancelled"):
        client.publish_templates({"厂家/b.json": TEMPLATE}, cancelled=lambda: next(checks))
    assert dav_server.files["/dav/templates/.catalog.json"] == current


@pytest.mark.parametrize("key", ["../a.json", "a/b/c.json", ".versions/x.json", "a\\b/c.json"])
def test_publish_rejects_unsafe_template_keys_before_network(dav_server, key):
    with pytest.raises(CloudSyncError):
        WebDavClient(dav_server.settings).publish_templates({key: TEMPLATE})
    assert dav_server.requests == []


@pytest.mark.parametrize("version", ["../outside", None, 123])
def test_bad_catalog_or_version_never_changes_cache(dav_server, tmp_path, version):
    client = WebDavClient(dav_server.settings)
    cache = tmp_path / "cache.json"
    atomic_json(cache, {"preserved": True})
    dav_server.files["/dav/templates/.catalog.json"] = json.dumps({
        "schema": 1, "version": version, "templates": {"Maker/a.json": TEMPLATE},
    }).encode()
    with pytest.raises(CloudSyncError):
        client.download_templates(cache_path=cache)
    assert json.loads(cache.read_text(encoding="utf-8")) == {"preserved": True}
    requests_before = len(dav_server.requests)
    with pytest.raises(CloudSyncError, match="version"):
        client.download_templates(cache_path=cache, version="../outside")
    assert len(dav_server.requests) == requests_before


def test_legacy_configuration_path_is_ignored(tmp_path: Path) -> None:
    path = tmp_path / "cloud.json"
    atomic_json(path, {
        "url": "https://example.com/dav/", "username": "alice", "mode": "publisher",
        "templates_path": "shared/templates", "configuration_path": "../legacy.json",
        "timeout": 25, "remember_password": True, "password": "secret",
    })
    settings = WebDavSettings.load(path).validated()
    assert settings.templates_path == "shared/templates"
    assert settings.mode == "publisher"
    assert settings.username == "alice"
    assert settings.password == "secret"
    assert settings.timeout == 25
    settings.save(path)
    assert "configuration_path" not in json.loads(path.read_text(encoding="utf-8"))
    assert WebDavSettings.load(path) == settings


def test_template_nested_path_and_empty_history(dav_server, tmp_path):
    client = WebDavClient(replace(dav_server.settings, templates_path="共享/模板"))
    client.test_connection()
    assert client.list_versions() == []
    version = client.publish_templates({"厂家/设备.json": TEMPLATE})
    assert client.list_versions() == [version]
    cache = tmp_path / "cache.json"
    assert client.download_templates(cache_path=cache) == 1
    assert json.loads(cache.read_text(encoding="utf-8")) == {"厂家/设备.json": TEMPLATE}
    assert ("MKCOL", "/dav/共享/") in dav_server.requests

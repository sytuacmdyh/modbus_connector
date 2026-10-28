import json
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib.metadata import version
from typing import Any
from urllib.error import URLError

import pytest

from modbus_connector import __version__, update_check
from modbus_connector.update_check import ReleaseInfo, UpdateCheckError, check_for_update


@pytest.fixture()
def github(monkeypatch: pytest.MonkeyPatch) -> Iterator[dict[str, Any]]:
    state = {"status": 200, "body": json.dumps({
        "tag_name": "v0.15.0", "body": "Changes\n<script>plain text</script>",
        "draft": False, "prerelease": False,
    }).encode()}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            state["headers"] = self.headers
            state["path"] = self.path
            self.send_response(state["status"])
            self.end_headers()
            self.wfile.write(state["body"])

        def log_message(self, *args: object) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    monkeypatch.setattr(update_check, "LATEST_RELEASE_API",
                        f"http://127.0.0.1:{server.server_port}/releases/latest")
    try:
        yield state
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


def test_release_request_and_safe_download_url(github: dict[str, Any]) -> None:
    release = check_for_update()
    assert release.tag == "v0.15.0"
    assert release.notes == "Changes\n<script>plain text</script>"
    assert release.url == "https://github.com/sytuacmdyh/modbus_connector/releases/tag/v0.15.0"
    assert github["path"] == "/releases/latest"
    assert github["headers"]["Authorization"] is None
    assert github["headers"]["User-Agent"] == f"ModbusConnector/{__version__}"


@pytest.mark.parametrize(("latest", "current", "newer"), [
    ("v0.15.0", "0.14.2", True),
    ("v0.14.10", "0.14.9", True),
    ("1.0.0", "0.99.99", True),
    ("v0.14.2", "0.14.2", False),
    ("v0.14.1", "0.14.2", False),
])
def test_numeric_version_comparison(latest: str, current: str, newer: bool) -> None:
    assert ReleaseInfo(latest, "").is_newer_than(current) is newer


@pytest.mark.parametrize(("status", "message"), [
    (404, None),
    (403, "GitHub denied"),
    (429, "GitHub denied"),
    (500, "GitHub request failed"),
])
def test_http_errors_are_not_reported_as_up_to_date(
    github: dict[str, Any], status: int, message: str | None,
) -> None:
    github["status"] = status
    if message is None:
        assert check_for_update() is None
    else:
        with pytest.raises(UpdateCheckError, match=message):
            check_for_update()


@pytest.mark.parametrize("payload", [
    b"not JSON", b"\xff", b"[]", b"{}", b"null",
    json.dumps({"tag_name": "v1.0.0", "draft": True, "prerelease": False}).encode(),
    json.dumps({"tag_name": "v1.0.0", "draft": False, "prerelease": True}).encode(),
    json.dumps({"tag_name": 15, "draft": False, "prerelease": False}).encode(),
    json.dumps({"tag_name": "v1.0.0-rc1", "draft": False, "prerelease": False}).encode(),
    json.dumps({"tag_name": "../../bad", "draft": False, "prerelease": False}).encode(),
    json.dumps({"tag_name": "v1.0.0", "draft": False,
                "prerelease": False, "body": []}).encode(),
    b" " * (1024 * 1024 + 1),
], ids=[
    "invalid-json", "invalid-encoding", "array", "missing-fields", "null",
    "draft", "prerelease", "invalid-tag-type", "release-candidate", "unsafe-tag",
    "invalid-notes", "oversized-response",
])
def test_reject_invalid_or_unstable_release(github: dict[str, Any], payload: bytes) -> None:
    github["body"] = payload
    with pytest.raises(UpdateCheckError):
        check_for_update()


def test_empty_release_notes(github: dict[str, Any]) -> None:
    github["body"] = b'{"tag_name":"v1.0.0","draft":false,"prerelease":false,"body":null}'
    assert check_for_update().notes == ""


@pytest.mark.parametrize("error", [URLError("offline"), TimeoutError("timed out")])
def test_network_errors(monkeypatch: pytest.MonkeyPatch, error: Exception) -> None:
    def fail(*args: object, **kwargs: object) -> None:
        assert kwargs["timeout"] == 10
        raise error

    monkeypatch.setattr(update_check, "urlopen", fail)
    with pytest.raises(UpdateCheckError, match="Could not reach GitHub"):
        check_for_update()


def test_package_and_runtime_version_agree() -> None:
    from packaging.version import Version

    assert Version(version("modbus-connector")) == Version(__version__)


def test_only_matching_verified_installer_is_selected(github):
    name = 'modbus-connector-1.0.0-windows-x64-setup.exe'
    url = f'https://github.com/{update_check.REPOSITORY}/releases/download/v1.0.0/{name}'
    asset = dict(name=name, browser_download_url=url, size=100, digest='sha256:' + 'a' * 64,
                 state='uploaded')
    data = dict(tag_name='v1.0.0', body='', draft=False, prerelease=False, assets=[asset])
    github['body'] = json.dumps(data).encode()
    assert check_for_update().installer == update_check.ReleaseAsset(url, 100, 'a' * 64)
    for key, bad in [('name', 'other.exe'), ('browser_download_url', 'https://evil.test/a'),
                     ('size', -1), ('size', True), ('size', 1024 ** 3 + 1),
                     ('digest', None), ('digest', 'md5:abcdef'), ('state', 'new')]:
        data['assets'] = [{**asset, key: bad}]
        github['body'] = json.dumps(data).encode()
        assert check_for_update().installer is None

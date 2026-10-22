"""Synchronous WebDAV synchronization; no Qt or additional dependencies."""

import base64
import json
import os
import re
import tempfile
import uuid
import xml.etree.ElementTree as ET
from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from email.message import Message
from http.client import HTTPException, HTTPResponse
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urljoin, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from modbus_connector import templates
from modbus_connector.settings_store import load_settings

CLOUD_SETTINGS_PATH = Path.home() / ".modbus_connector" / "cloud.json"
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_TEMPLATES = 1000
DAV = "{DAV:}"
PROPFIND_BODY = (
    b'<?xml version="1.0" encoding="utf-8"?>'
    b'<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>'
)


class CloudSyncError(Exception):
    def __init__(self, key: str, **params: object) -> None:
        self.key = key
        self.params = params
        super().__init__(key.format(**params))


def relative_path(value: str) -> str:
    parts = value.split("/")
    if not value or any(p in ("", ".", "..") for p in parts) or any(
        c in value for c in "\\\x00\r\n?#"
    ):
        raise CloudSyncError("Enter a relative cloud path without '..'.")
    return value


@dataclass(frozen=True)
class WebDavSettings:
    url: str = ""
    username: str = ""
    password: str = field(default="", repr=False)
    templates_path: str = "templates"
    timeout: int = 15
    remember_password: bool = False
    mode: str = "consumer"

    def validated(self) -> "WebDavSettings":
        try:
            parsed = urlsplit(self.url)
            port = parsed.port
        except ValueError as exc:
            raise CloudSyncError("Enter a valid HTTP or HTTPS WebDAV URL.") from exc
        if (
            parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username is not None or parsed.password is not None
            or parsed.query or parsed.fragment or port == 0
            or any(ord(c) < 33 for c in self.url)
            or any(p in (".", "..") for p in unquote(parsed.path).split("/"))
        ):
            raise CloudSyncError("Enter a valid HTTP or HTTPS WebDAV URL.")
        if ":" in self.username or any(c in self.username for c in "\r\n"):
            raise CloudSyncError("Invalid WebDAV username.")
        relative_path(self.templates_path)
        if not 1 <= self.timeout <= 120:
            raise CloudSyncError("Timeout must be between 1 and 120 seconds.")
        if self.mode not in ("publisher", "consumer"):
            raise CloudSyncError("Invalid cloud mode.")
        return self

    @classmethod
    def load(cls, path: Path | None = None) -> "WebDavSettings":
        data = load_settings(path or CLOUD_SETTINGS_PATH)
        defaults = cls()
        values = {
            name: data.get(name, getattr(defaults, name))
            for name in ("url", "username", "password", "templates_path")
        }
        values = {k: v if isinstance(v, str) else getattr(defaults, k) for k, v in values.items()}
        timeout = data.get("timeout", 15)
        values["timeout"] = timeout if type(timeout) is int and 1 <= timeout <= 120 else 15
        values["remember_password"] = data.get("remember_password") is True
        values["mode"] = data.get("mode") if data.get("mode") in (
            "publisher", "consumer",
        ) else "consumer"
        if not values["remember_password"]:
            values["password"] = ""
        return cls(**values)

    def save(self, path: Path | None = None) -> None:
        data = asdict(self.validated())
        if not self.remember_password:
            data.pop("password")
        atomic_json(path or CLOUD_SETTINGS_PATH, data)


def atomic_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, delete=False,
        ) as stream:
            temporary = stream.name
            json.dump(data, stream, ensure_ascii=False, indent=2, allow_nan=False)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(
        self, req: Request, fp: HTTPResponse, code: int, msg: str, headers: Message, newurl: str,
    ) -> None:
        return None  # credentials must never follow a redirect


class WebDavClient:
    def __init__(self, settings: WebDavSettings) -> None:
        self.settings = settings.validated()
        parsed = urlsplit(settings.url)
        self.base_url = urlunsplit((
            parsed.scheme, parsed.netloc, quote(unquote(parsed.path).rstrip("/") + "/", safe="/"),
            "", "",
        ))
        self._opener = build_opener(_NoRedirect())

    def _url(self, path: str = "", *, collection: bool = False) -> str:
        suffix = quote(relative_path(path), safe="/") if path else ""
        return self.base_url + suffix + ("/" if collection and suffix else "")

    def _request(
        self, method: str, path: str = "", *, collection: bool = False,
        body: bytes | None = None, depth: str = "1", allowed: tuple[int, ...] = (200,),
    ) -> bytes:
        if method not in ("GET", "PROPFIND"):
            self._require_publisher()
        headers = {"User-Agent": "ModbusConnector", "Cache-Control": "no-cache"}
        if self.settings.username or self.settings.password:
            token = base64.b64encode(
                f"{self.settings.username}:{self.settings.password}".encode()
            ).decode("ascii")
            headers["Authorization"] = f"Basic {token}"
        if method == "PROPFIND":
            headers.update({"Depth": depth, "Content-Type": "application/xml; charset=utf-8"})
        elif method == "PUT":
            headers["Content-Type"] = "application/json; charset=utf-8"
        request = Request(self._url(path, collection=collection), body, headers, method=method)
        try:
            with self._opener.open(request, timeout=self.settings.timeout) as response:
                if response.status not in allowed:
                    raise CloudSyncError("WebDAV {method} failed: HTTP {status}.",
                                         method=method, status=response.status)
                result = response.read(MAX_RESPONSE_BYTES + 1)
                if len(result) > MAX_RESPONSE_BYTES:
                    raise CloudSyncError("Cloud response exceeds the 16 MiB limit.")
                return result
        except HTTPError as exc:
            exc.close()
            if exc.code in allowed:
                return b""
            raise CloudSyncError("WebDAV {method} failed: HTTP {status}.",
                                 method=method, status=exc.code) from exc
        except (URLError, OSError, ValueError, HTTPException) as exc:
            raise CloudSyncError("WebDAV connection failed: {detail}",
                                 detail=str(getattr(exc, "reason", exc))) from exc

    def _listing(self, path: str = "", depth: str = "1") -> list[tuple[str, bool]]:
        body = self._request("PROPFIND", path, collection=True, body=PROPFIND_BODY,
                             depth=depth, allowed=(207,))
        try:
            root = ET.fromstring(body)
        except ET.ParseError as exc:
            raise CloudSyncError("Invalid WebDAV directory response.") from exc
        if root.tag != DAV + "multistatus":
            raise CloudSyncError("Invalid WebDAV directory response.")
        target = urlsplit(self._url(path, collection=True))
        target_path = unquote(target.path).rstrip("/")
        entries: dict[str, bool] = {}
        for response in root.findall(DAV + "response"):
            href = response.findtext(DAV + "href", "")
            if not href:
                raise CloudSyncError("Invalid WebDAV directory response.")
            resolved = urlsplit(urljoin(self._url(path, collection=True), href))
            if (resolved.scheme, resolved.netloc) != (target.scheme, target.netloc):
                raise CloudSyncError("Invalid WebDAV directory response.")
            decoded = unquote(resolved.path).rstrip("/")
            if decoded != target_path and not decoded.startswith(target_path + "/"):
                raise CloudSyncError("Invalid WebDAV directory response.")
            name = decoded[len(target_path):].lstrip("/")
            if name and ("/" in name or name in (".", "..") or "\\" in name):
                raise CloudSyncError("Invalid WebDAV directory response.")
            resource_type = None
            for propstat in response.findall(DAV + "propstat"):
                status = propstat.findtext(DAV + "status", "").split()
                if len(status) >= 2 and status[1] == "200":
                    resource_type = propstat.find(f"{DAV}prop/{DAV}resourcetype")
                    if resource_type is not None:
                        break
            if resource_type is None:
                raise CloudSyncError("Invalid WebDAV directory response.")
            entries[name] = resource_type.find(DAV + "collection") is not None
        if entries.get("") is not True:
            raise CloudSyncError("Invalid WebDAV directory response.")
        return [(name, collection) for name, collection in entries.items() if name]

    def test_connection(self) -> None:
        self._listing(depth="0")

    def _require_publisher(self) -> None:
        if self.settings.mode != "publisher":
            raise CloudSyncError("Consumer mode cannot publish templates.")

    def _optional_get(self, path: str) -> bytes | None:
        try:
            return self._request("GET", path)
        except CloudSyncError as exc:
            if exc.params.get("status") == 404:
                return None
            raise

    def _mkdirs(self, directory: str) -> None:
        parts = relative_path(directory).split("/")
        for i in range(1, len(parts) + 1):
            self._request("MKCOL", "/".join(parts[:i]), collection=True, allowed=(201, 405))

    def _put(self, path: str, raw: bytes) -> None:
        parent, _, _ = path.rpartition("/")
        if parent:
            self._mkdirs(parent)
        self._request("PUT", path, body=raw, allowed=(200, 201, 204))

    @staticmethod
    def _json_bytes(data: object) -> bytes:
        raw = json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False).encode("utf-8")
        if len(raw) > MAX_RESPONSE_BYTES:
            raise CloudSyncError("Cloud response exceeds the 16 MiB limit.")
        return raw

    @staticmethod
    def _version(value: str | None = None) -> str:
        if value is None:
            return datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ-") + uuid.uuid4().hex[:8]
        if not re.fullmatch(r"[0-9]{8}T[0-9]{12}Z-[a-f0-9]{8}", value):
            raise CloudSyncError("Invalid cloud version.")
        return value

    def _history_path(self) -> str:
        return self.settings.templates_path + "/.versions"

    def list_versions(self) -> list[str]:
        try:
            entries = self._listing(self._history_path())
        except CloudSyncError as exc:
            if exc.params.get("status") == 404:
                return []
            raise
        versions = []
        for name, directory in entries:
            if not directory and name.endswith(".json"):
                try:
                    versions.append(self._version(name[:-5]))
                except CloudSyncError:
                    continue
        return sorted(versions, reverse=True)

    def _catalog(self, raw: bytes) -> dict[str, Any]:
        try:
            data = json.loads(raw.decode("utf-8-sig"))
            if (not isinstance(data, dict) or data.get("schema") != 1
                    or not isinstance(data.get("version"), str)):
                raise ValueError
            self._version(data["version"])
            self._validate_templates(data["templates"])
            return data
        except (ValueError, UnicodeError, KeyError, TypeError) as exc:
            raise CloudSyncError("Invalid cloud template catalog.") from exc

    @staticmethod
    def _validate_templates(catalog: object) -> None:
        if not isinstance(catalog, dict) or not catalog or len(catalog) > MAX_TEMPLATES:
            raise CloudSyncError("Invalid cloud template catalog.")
        for resource, data in catalog.items():
            if (not isinstance(resource, str) or len(resource.split("/")) != 2
                    or not resource.endswith(".json")):
                raise CloudSyncError("Invalid cloud template catalog.")
            relative_path(resource)
            if resource.split("/")[0].startswith("."):
                raise CloudSyncError("Invalid cloud template catalog.")
            if templates.parse_template(json.dumps(data, allow_nan=False), resource) is None:
                raise CloudSyncError("Invalid cloud template: {name}", name=resource)

    def publish_templates(
        self, catalog: dict[str, Any], *, cancelled: Callable[[], bool] = lambda: False,
    ) -> str:
        self._require_publisher()
        self._validate_templates(catalog)
        version = self._version()
        raw = self._json_bytes({"schema": 1, "version": version, "templates": catalog})
        if cancelled():
            raise CloudSyncError("Cloud operation cancelled.")
        self._put(f"{self._history_path()}/{version}.json", raw)
        if cancelled():
            raise CloudSyncError("Cloud operation cancelled.")
        # A complete immutable snapshot exists before the current catalog changes.
        self._put(f"{self.settings.templates_path}/.catalog.json", raw)
        return version

    def activate_version(
        self, version: str, *, cancelled: Callable[[], bool] = lambda: False,
    ) -> str:
        self._require_publisher()
        self._version(version)
        raw = self._request("GET", f"{self._history_path()}/{version}.json")
        return self.publish_templates(self._catalog(raw)["templates"], cancelled=cancelled)

    def download_templates(
        self, *, cache_path: Path | None = None, cancelled: Callable[[], bool] = lambda: False,
        version: str | None = None,
    ) -> int:
        downloaded: dict[str, Any] = {}
        total_bytes = 0

        def check_cancelled() -> None:
            if cancelled():
                raise CloudSyncError("Cloud operation cancelled.")

        check_cancelled()
        catalog_path = (f"{self._history_path()}/{self._version(version)}.json"
                        if version is not None else f"{self.settings.templates_path}/.catalog.json")
        raw_catalog = (self._request("GET", catalog_path) if version is not None
                       else self._optional_get(catalog_path))
        if raw_catalog is not None:
            downloaded = self._catalog(raw_catalog)["templates"]
            check_cancelled()
            atomic_json(cache_path or templates.CLOUD_TEMPLATES_PATH, downloaded)
            return len(downloaded)
        for manufacturer, is_directory in self._listing(self.settings.templates_path):
            check_cancelled()
            if not is_directory or manufacturer.startswith("."):
                continue
            directory = f"{self.settings.templates_path}/{manufacturer}"
            for filename, is_collection in self._listing(directory):
                check_cancelled()
                if is_collection or not filename.endswith(".json"):
                    continue
                if len(downloaded) >= MAX_TEMPLATES:
                    raise CloudSyncError("Cloud template catalog is too large.")
                raw = self._request("GET", f"{directory}/{filename}")
                total_bytes += len(raw)
                if total_bytes > MAX_RESPONSE_BYTES:
                    raise CloudSyncError("Cloud template catalog is too large.")
                resource = f"{manufacturer}/{filename}"
                try:
                    data = templates.parse_template(raw.decode("utf-8-sig"), resource)
                except UnicodeError as exc:
                    raise CloudSyncError("Invalid cloud template: {name}", name=resource) from exc
                if data is None:
                    raise CloudSyncError("Invalid cloud template: {name}", name=resource)
                downloaded[resource] = data
        check_cancelled()
        atomic_json(cache_path or templates.CLOUD_TEMPLATES_PATH, downloaded)
        return len(downloaded)

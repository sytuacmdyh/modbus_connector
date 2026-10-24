"""Cancellable WebDAV transfers and release checks for the Flutter desktop UI."""

from __future__ import annotations

import os
import subprocess
import sys
import threading
from dataclasses import asdict
from typing import Any

from . import __version__
from .cloud_sync import CloudSyncError, WebDavClient, WebDavSettings
from .flutter_catalog import flutter_directory, public_catalog, public_template
from .flutter_registers import bounded
from .update_check import RELEASES_URL, UpdateCheckError, check_for_update


def message(exc: Exception) -> str:
    return (
        str(exc).format(**getattr(exc, "params", {})) if getattr(exc, "params", None) else str(exc)
    )


class FlutterOnline:
    def __init__(self) -> None:
        self._cancel = threading.Event()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._result: dict[str, Any] = {}
        self._release_url = RELEASES_URL

    def close(self) -> None:
        self._cancel.set()
        if self._thread is not None:
            self._thread.join(timeout=2)

    @staticmethod
    def settings(data: object) -> WebDavSettings:
        if not isinstance(data, dict):
            raise ValueError("settings must be an object")
        fields = ("url", "username", "password", "templates_path")
        defaults = WebDavSettings()
        if any(not isinstance(data.get(f, getattr(defaults, f)), str) for f in fields):
            raise ValueError("Cloud connection fields must be strings")
        return WebDavSettings(
            **{f: data.get(f, getattr(defaults, f)) for f in fields},
            timeout=bounded(data.get("timeout", 15), "timeout", 1, 120),
            remember_password=data.get("remember_password") is True,
            mode=data.get("mode", "consumer"),
        ).validated()

    def dispatch(self, data: dict[str, Any]) -> dict[str, Any]:
        command = data["command"]
        if command == "cloud_settings_load":
            return {"settings": asdict(WebDavSettings.load(flutter_directory() / "cloud.json"))}
        if command == "cloud_settings_save":
            self.settings(data.get("settings")).save(flutter_directory() / "cloud.json")
            return {}
        if command == "cloud_cancel":
            self._cancel.set()
            return {}
        if command == "cloud_status":
            with self._lock:
                return {
                    **self._result,
                    "running": self._thread is not None and self._thread.is_alive(),
                }
        if command == "cloud_start":
            if self._thread is not None and self._thread.is_alive():
                raise ValueError("Cloud transfer already running")
            settings = self.settings(data.get("settings"))
            action = data.get("action")
            if action not in ("test", "download", "versions", "publish", "activate"):
                raise ValueError("Unknown cloud action")
            if action in ("publish", "activate") and settings.mode != "publisher":
                raise CloudSyncError("Publishing is disabled in consumer mode.")
            version = data.get("version")
            if action == "activate" and not isinstance(version, str):
                raise ValueError("Select a version")
            catalog = (
                {t.resource: public_template(t.resource) for t in public_catalog()}
                if action == "publish"
                else {}
            )
            self._cancel.clear()
            self._result = {"action": action, "error": None, "result": None}

            def work() -> None:
                try:
                    client = WebDavClient(settings)
                    if action == "test":
                        client.test_connection()
                        result = {"message": "Connection successful"}
                    elif action == "versions":
                        result = {"versions": client.list_versions()}
                    elif action == "download":
                        result = {
                            "downloaded": client.download_templates(
                                cache_path=flutter_directory() / "cloud_templates.json",
                                version=version,
                                cancelled=self._cancel.is_set,
                            )
                        }
                    elif action == "publish":
                        result = {
                            "version": client.publish_templates(
                                catalog, cancelled=self._cancel.is_set
                            )
                        }
                    else:
                        result = {
                            "version": client.activate_version(
                                version, cancelled=self._cancel.is_set
                            )
                        }
                    with self._lock:
                        self._result["result"] = result
                        if self._cancel.is_set():
                            self._result["error"] = "Cloud operation cancelled."
                except Exception as exc:
                    with self._lock:
                        self._result["error"] = message(exc)

            self._thread = threading.Thread(target=work, name="flutter-webdav", daemon=True)
            self._thread.start()
            return {"started": True}
        if command == "update_check":
            try:
                release = check_for_update()
            except UpdateCheckError as exc:
                return {
                    "current": __version__,
                    "release": None,
                    "url": self._release_url,
                    "newer": False,
                    "install_supported": False,
                    "install_reason": message(exc),
                    "error": message(exc),
                }
            if release:
                self._release_url = release.url
            return {
                "current": __version__,
                "release": asdict(release) if release else None,
                "url": self._release_url,
                "newer": release.is_newer_than(__version__) if release else False,
                "install_supported": False,
                "install_reason": (
                    "Automatic installation requires a Flutter-specific installer. "
                    "The current Windows installer is for the Qt application. "
                    "Use the releases page for manual installation."
                ),
            }
        if command == "update_install":
            raise ValueError(
                "Automatic installation requires a Flutter-specific installer; "
                "use manual installation."
            )
        if command == "update_open_page":
            if sys.platform == "win32":
                os.startfile(self._release_url)
            else:
                subprocess.Popen(
                    ["open" if sys.platform == "darwin" else "xdg-open", self._release_url],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            return {"url": self._release_url}
        raise ValueError("Unknown cloud/update command")

"""Publish selected templates using the application's headless WebDAV protocol."""

import argparse
import getpass
import json
import os
import sys
import tempfile
from dataclasses import replace
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit, urlunsplit

from modbus_connector.cloud_sync import CloudSyncError, WebDavClient, WebDavSettings, atomic_json

SKILL_DIR = Path(__file__).resolve().parents[1]


def config_path() -> Path:
    directory = Path(os.environ.get(
        "MODBUS_TEMPLATE_UPLOAD_HOME",
        str(Path.home() / ".modbus_connector" / "skills" / "template-upload"),
    )).expanduser().resolve()
    path = (directory / "config.json").resolve()
    if path.is_relative_to(SKILL_DIR):
        raise ValueError("Configuration must be outside the skill directory.")
    return path


def settings(config: dict[str, Any]) -> WebDavSettings:
    url = config.get("url")
    if not isinstance(url, str) or not url:
        raise ValueError("Upload URL is missing; ask the user to enter it and run configure.")
    # Validate the original URL before splitting off its final directory component.
    original = WebDavSettings(
        url=url, username=config.get("username", ""), timeout=config.get("timeout", 15),
        mode="publisher",
    ).validated()
    parsed = urlsplit(url)
    parent, _, directory = unquote(parsed.path).rstrip("/").rpartition("/")
    if not directory:
        raise ValueError("URL must name a template directory, not the server root.")
    return replace(
        original, url=urlunsplit((parsed.scheme, parsed.netloc, parent, "", "")),
        templates_path=directory,
    ).validated()


def configure(
    url: str, username: str = "", timeout: int = 15, *, password: str | None = None,
) -> Path:
    config = {"url": url, "username": username, "timeout": timeout}
    if password is not None:
        config["password"] = password
    settings(config)
    path = config_path()
    atomic_json(path, config)
    path.chmod(0o600)
    return path


def load_config() -> dict[str, Any]:
    path = config_path()
    if not path.exists():
        raise ValueError(f"Not configured: {path}. Ask the user for the upload URL.")
    config = json.loads(path.read_text(encoding="utf-8"))
    required = {"url", "username", "timeout"}
    if (not isinstance(config, dict) or not required <= set(config)
            or set(config) - required - {"password"}):
        raise ValueError("Invalid configuration; run configure with the user's supplied URL.")
    if not isinstance(config["username"], str) or type(config["timeout"]) is not int:
        raise ValueError("Invalid username/timeout configuration.")
    if "password" in config and not isinstance(config["password"], str):
        raise ValueError("Invalid saved password configuration.")
    settings(config)
    return config


def password_for(config: dict[str, Any]) -> str:
    password = os.environ.get("MODBUS_TEMPLATE_UPLOAD_PASSWORD", config.get("password", ""))
    if config.get("username") and not password:
        if not sys.stdin.isatty():
            raise ValueError("Set MODBUS_TEMPLATE_UPLOAD_PASSWORD or use an interactive terminal.")
        password = getpass.getpass("WebDAV password: ")
    return password


def local_templates(paths: list[Path], resource: str | None = None) -> dict[str, Any]:
    if resource and len(paths) != 1:
        raise ValueError("--resource requires exactly one file.")
    catalog: dict[str, Any] = {}
    for path in paths:
        key = resource or f"{path.parent.name}/{path.name}"
        if key in catalog:
            raise ValueError(f"Duplicate resource: {key}")
        catalog[key] = json.loads(path.read_text(encoding="utf-8-sig"))
    WebDavClient._validate_templates(catalog)
    return catalog


def remote_templates(client: WebDavClient) -> dict[str, Any]:
    raw = client._optional_get(f"{client.settings.templates_path}/.catalog.json")
    if raw is not None:
        return client._catalog(raw)["templates"]
    # Only a missing top-level template directory means an empty destination.
    # A 404 while traversing an existing legacy catalog must abort publication.
    try:
        client._listing(client.settings.templates_path)
    except CloudSyncError as exc:
        if exc.params.get("status") == 404:
            return {}
        raise
    with tempfile.TemporaryDirectory(prefix="modbus-template-upload-") as temporary:
        cache = Path(temporary) / "catalog.json"
        client.download_templates(cache_path=cache)
        return json.loads(cache.read_text(encoding="utf-8"))


def upload(client: WebDavClient, selected: dict[str, Any], *, publish: bool) -> dict[str, Any]:
    WebDavClient._validate_templates(selected)
    remote = remote_templates(client)
    actions = {key: ("unchanged" if remote.get(key) == value else
                     "replace" if key in remote else "add") for key, value in selected.items()}
    merged = {**remote, **selected}
    WebDavClient._validate_templates(merged)
    client._json_bytes({"schema": 1, "version": client._version(), "templates": merged})
    result: dict[str, Any] = {"actions": actions, "total_templates": len(merged),
                              "published": False}
    if publish and any(action != "unchanged" for action in actions.values()):
        version = client.publish_templates(merged)
        raw = client._request("GET", f"{client.settings.templates_path}/.catalog.json")
        current = client._catalog(raw)
        if current["version"] != version or current["templates"] != merged:
            raise ValueError(
                f"Read-back mismatch after publishing {version}; inspect remote state.",
            )
        result.update(published=True, version=version, verified=True)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("configure")
    setup.add_argument("--url", required=True)
    setup.add_argument("--username", default="")
    setup.add_argument("--timeout", type=int, default=15)
    setup.add_argument("--remember-password", action="store_true")
    commands.add_parser("config-show")
    push = commands.add_parser("upload")
    push.add_argument("files", nargs="+", type=Path)
    push.add_argument("--resource")
    push.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "configure":
            password = password_for({"username": args.username}) if args.remember_password else None
            print(configure(args.url, args.username, args.timeout, password=password))
        elif args.command == "config-show":
            config = load_config()
            public = {key: value for key, value in config.items() if key != "password"}
            print(json.dumps({"path": str(config_path()), **public,
                              "password_saved": bool(config.get("password"))}, ensure_ascii=False))
        else:
            config = load_config()
            selected = local_templates(args.files, args.resource)
            password = password_for(config)
            client = WebDavClient(replace(settings(config), password=password))
            result = upload(client, selected, publish=args.publish)
            print(json.dumps({"url": config["url"], **result}, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, CloudSyncError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

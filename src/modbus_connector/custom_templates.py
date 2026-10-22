"""Local, versioned user templates. Public catalogs are never written here."""

import json
import logging
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from uuid import uuid4

from modbus_connector.cloud_sync import atomic_json
from modbus_connector.templates import parse_template

CUSTOM_TEMPLATES_PATH = Path.home() / ".modbus_connector" / "custom_templates"
log = logging.getLogger(__name__)
_SESSION_KEYS = (
    "mode", "connection", "registers", "registers_options", "expressions",
    "logging", "scanner", "sim", "sniffer", "gateway",
)


@dataclass(frozen=True)
class CustomTemplateInfo:
    id: str
    name: str


class CustomTemplateStore:
    def __init__(self, root: Path | None = None) -> None:
        self.root = root if root is not None else CUSTOM_TEMPLATES_PATH

    def _path(self, template_id: str) -> Path:
        if not re.fullmatch(r"[0-9a-f]{32}", template_id):
            raise ValueError("Invalid custom template ID.")
        return self.root / f"{template_id}.json"

    def _read(self, template_id: str) -> dict[str, Any]:
        data = json.loads(self._path(template_id).read_text(encoding="utf-8"))
        if (
            not isinstance(data, dict) or data.get("schema") != 1
            or not isinstance(data.get("name"), str) or not data["name"].strip()
            or not isinstance(data.get("versions"), list) or not data["versions"]
        ):
            raise ValueError("Invalid custom template file.")
        ids: set[str] = set()
        for version in data["versions"]:
            if (
                not isinstance(version, dict) or not isinstance(version.get("id"), str)
                or version["id"] in ids or not isinstance(version.get("saved_at"), str)
                or parse_template(json.dumps(version.get("state")), template_id) is None
            ):
                raise ValueError("Invalid custom template version.")
            datetime.fromisoformat(version["saved_at"])
            ids.add(version["id"])
        return data

    def list_templates(self) -> list[CustomTemplateInfo]:
        result = []
        for path in self.root.glob("*.json"):
            try:
                data = self._read(path.stem)
            except (OSError, ValueError) as exc:
                log.warning("Skipping custom template %s: %s", path.name, exc)
                continue
            result.append(CustomTemplateInfo(path.stem, data["name"]))
        return sorted(result, key=lambda info: (info.name.casefold(), info.id))

    def versions(self, template_id: str) -> list[dict[str, str]]:
        return [
            {"id": version["id"], "saved_at": version["saved_at"]}
            for version in reversed(self._read(template_id)["versions"])
        ]

    def load(self, template_id: str, version_id: str | None = None) -> dict[str, Any]:
        data = self._read(template_id)
        for version in reversed(data["versions"]):
            if version_id is None or version["id"] == version_id:
                return {**version["state"], "name": data["name"]}
        raise ValueError("Custom template version not found.")

    @staticmethod
    def _name(name: str) -> str:
        name = name.strip()
        if not name:
            raise ValueError("Template name cannot be empty.")
        return name

    def save(
        self, state: dict[str, Any], *, name: str | None = None,
        template_id: str | None = None,
    ) -> CustomTemplateInfo:
        if template_id is None:
            template_id = uuid4().hex
            data = {"schema": 1, "name": self._name(name or ""), "versions": []}
        else:
            data = self._read(template_id)
        snapshot = {key: state[key] for key in _SESSION_KEYS if key in state}
        snapshot["name"] = data["name"]
        if parse_template(json.dumps(snapshot, allow_nan=False)) is None:
            raise ValueError("Invalid custom template state.")
        now = datetime.now(UTC)
        data["versions"].append({
            "id": now.strftime("%Y%m%dT%H%M%S.%fZ") + "-" + uuid4().hex[:8],
            "saved_at": now.isoformat(), "state": snapshot,
        })
        atomic_json(self._path(template_id), data)
        return CustomTemplateInfo(template_id, data["name"])

    def rename(self, template_id: str, name: str) -> None:
        data = self._read(template_id)
        data["name"] = self._name(name)
        atomic_json(self._path(template_id), data)

    def delete(self, template_id: str) -> None:
        self._path(template_id).unlink()

    def delete_version(self, template_id: str, version_id: str) -> None:
        data = self._read(template_id)
        versions = [v for v in data["versions"] if v["id"] != version_id]
        if len(versions) == len(data["versions"]):
            raise ValueError("Custom template version not found.")
        if not versions:
            raise ValueError("Cannot delete the last version; delete the template instead.")
        data["versions"] = versions
        atomic_json(self._path(template_id), data)

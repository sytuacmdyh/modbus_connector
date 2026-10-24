"""Public catalog reads and separately owned Flutter custom-template history."""

from __future__ import annotations

import json
import logging
import os
from dataclasses import asdict
from pathlib import Path
from typing import Any

from .custom_templates import CustomTemplateStore
from .templates import TemplateInfo, list_templates, load_template


def flutter_directory() -> Path:
    configured = os.environ.get("MODBUS_FLUTTER_HOME")
    return Path(configured) if configured else Path.home() / ".modbus_connector" / "flutter"


def cached_templates() -> dict[str, Any]:
    try:
        raw = json.loads((flutter_directory() / "cloud_templates.json").read_text(encoding="utf-8"))
        from .cloud_sync import WebDavClient

        WebDavClient._validate_templates(raw)
        return raw
    except FileNotFoundError:
        return {}
    except Exception as exc:
        logging.getLogger(__name__).warning("Ignoring invalid Flutter template cache: %s", exc)
        return {}


def public_catalog() -> list[TemplateInfo]:
    found = {t.resource: t for t in list_templates()}
    for resource, state in cached_templates().items():
        found[resource] = TemplateInfo(
            state["name"], resource.split("/")[0], resource, str(state.get("description", ""))
        )
    return sorted(found.values(), key=lambda t: (t.manufacturer.casefold(), t.name.casefold()))


def public_template(resource: str) -> dict[str, Any]:
    return cached_templates().get(resource) or load_template(resource)


def flutter_state(state: dict[str, Any]) -> dict[str, Any]:
    connection = state.get("connection", {})
    extra = state.get("registers_options", {}).get("flutter", {})
    if "transport" not in connection:
        transport = {"TCP": "tcp", "RTU over TCP": "rtu_tcp", "RTU over UDP": "rtu_udp"}.get(
            connection.get("type"), "rtu"
        )
        connection = {
            "transport": transport,
            "host": connection.get("tcp_host", "127.0.0.1"),
            "port": connection.get("rtu_port", "")
            if transport == "rtu"
            else int(connection.get("tcp_port", 502)),
            "baudrate": int(connection.get("rtu_baud", 9600)),
            "bytesize": int(connection.get("rtu_bytesize", 8)),
            "parity": connection.get("rtu_parity", "N"),
            "stopbits": int(connection.get("rtu_stopbits", 1)),
            "timeout": connection.get("timeout", 3),
        }
    draft = {
        "transport": connection.get("transport", "rtu"),
        "host": str(connection.get("host", "127.0.0.1")),
        "port": str(connection.get("port", 502)) if connection.get("transport") != "rtu" else "502",
        "serial": str(connection.get("port", "")) if connection.get("transport") == "rtu" else "",
        "baud": str(connection.get("baudrate", 9600)),
        "parity": connection.get("parity", "N"),
        "bits": connection.get("bytesize", 8),
        "stop": connection.get("stopbits", 1),
        "timeout": str(connection.get("timeout", 3)),
    }
    mode = {"sim": "simulator", "slave": "simulator"}.get(
        state.get("mode"), state.get("mode", "master")
    )
    device = extra.get("device_config", state.get("device_config", {}))
    if not device and mode == "simulator":
        sim = state.get("sim", {})
        server = sim.get("server", {})
        listen = flutter_state({"connection": {
            **server, "tcp_host": server.get("host", "127.0.0.1"),
            "tcp_port": server.get("port", 1502),
        }})["connection"]
        device = {
            "listen": listen, "tick_ms": sim.get("tick_ms", 1000),
            "units_text": "" if server.get("unit", "any") == "any" else str(server["unit"]),
        }
    elif not device and mode == "gateway":
        gateway = state.get("gateway", {})
        device = {
            key: flutter_state({"connection": gateway.get(key, {})})["connection"]
            for key in ("listen", "target")
        }
        device["units_text"] = gateway.get("units", "")
    elif not device and mode == "sniffer":
        device = {"listen": {"transport": "rtu", **state.get("sniffer", {}).get("params", {})}}
    options = state.get("registers_options", {})
    column_keys = {"type": "kind", "poll_enabled": "poll"}
    layout = {
        "order": [column_keys.get(k, k) for k in options.get("column_order", [])],
        "hidden": [column_keys.get(k, k) for k in options.get("hidden_columns", [])],
    }
    expressions = [
        {**e, "text": e.get("text", e.get("expr", ""))}
        for e in state.get("expressions", []) if isinstance(e, dict)
    ]
    def normalize_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
        normalized = []
        for row in rows:
            # Qt templates omit defaults; Flutter validates and renders explicit fields.
            item = {
                "name": "", "kind": "holding_registers", "address": 0, "count": 1,
                "format": "dec", "scale": 1, "offset": 0, "unit": "",
                **row, "order": row.get("order") or options.get("order") or "ABCD",
            }
            for key in ("unit_id", "poll_ms"):
                value = item.get(key)
                item[key] = None if value is None or value == "" else int(value)
            normalized.append(item)
        return normalized

    sniffed: dict[str, Any] = {}
    for entry in state.get("sniffer", {}).get("units", []):
        recovered: dict[str, Any] = {}
        for row in entry.get("rows", []):
            values = row.get("value", [])
            for offset, value in enumerate(values):
                address = row["address"] + offset
                recovered[f"{row['kind']}/{address}"] = {
                    **row, "address": address, "value": value, "count": 1,
                }
        sniffed[str(entry["unit"])] = recovered
    return {
        **state,
        **extra,
        "connection": connection,
        "draft": {**draft, "map_table": layout, **state.get("draft", {}), **extra.get("draft", {})},
        "mode": mode,
        "expressions": expressions,
        "registers": normalize_rows(state.get("registers", [])),
        "sniffed": extra.get("sniffed", state.get("sniffed", sniffed)),
        "map_grouped": extra.get(
            "map_grouped", state.get("map_grouped", options.get("group_reads", False))
        ),
        "device_config": device,
        "unit": extra.get("unit", state.get("connection", {}).get("unit", 1)),
        "sim_rows": normalize_rows(extra.get("sim_rows", state.get("sim", {}).get("rows", []))),
    }


def catalog_command(data: dict[str, Any]) -> dict[str, Any]:
    store = CustomTemplateStore(flutter_directory() / "custom_templates")
    command = data["command"]
    if command == "template_convert_workspace":
        workspace = data.get("workspace")
        if (not isinstance(workspace, dict) or not isinstance(workspace.get("tabs"), list)
                or not 1 <= len(workspace["tabs"]) <= 64
                or any(not isinstance(tab, dict) for tab in workspace["tabs"])):
            raise ValueError("Configuration requires 1..64 session objects")
        allowed = {
            "mode", "connection", "registers", "expressions", "draft", "unit", "query",
            "interval_ms", "device_config", "sim_rows", "map_grouped", "logging",
            "scanner", "sniffed",
        }
        return {
            "schema": 1,
            "tabs": [{k: v for k, v in flutter_state(tab).items() if k in allowed}
                     for tab in workspace["tabs"]],
            "active_tab": workspace.get("active_tab", 0),
        }
    if command == "template_list":
        return {
            "public": [asdict(t) for t in public_catalog()],
            "custom": [asdict(t) for t in store.list_templates()],
        }
    template_id = data.get("template_id")
    if command == "template_load":
        state = (
            store.load(template_id, data.get("version_id"))
            if template_id
            else public_template(data.get("resource", ""))
        )
        return {"state": flutter_state(state), "template_id": template_id}
    if command == "template_versions":
        return {"versions": store.versions(template_id)}
    if command == "template_save":
        state = data.get("state")
        if not isinstance(state, dict):
            raise ValueError("state must be an object")
        # The shared store keeps only known Qt snapshot keys; preserve Flutter
        # connection/query/mode data inside its existing options section.
        state = {
            **state,
            "registers_options": {
                "flutter": {
                    k: state[k]
                    for k in (
                        "query",
                        "draft",
                        "unit",
                        "interval_ms",
                        "device_config",
                        "sim_rows",
                        "map_grouped",
                        "sniffed",
                    )
                    if k in state
                }
            },
        }
        info = store.save(state, name=data.get("name"), template_id=template_id)
        return asdict(info)
    if command == "template_rename":
        store.rename(template_id, data.get("name", ""))
    elif command == "template_delete":
        store.delete(template_id)
    elif command == "template_delete_version":
        store.delete_version(template_id, data.get("version_id", ""))
    else:
        raise ValueError("Unknown template command")
    return {}

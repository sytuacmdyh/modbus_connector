"""Shared public-template payloads for tests (cloud cache, not bundled assets)."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

FIXTURE_RESOURCE = "Acme/TestMeter.json"
FIXTURE_KEY = "Acme/TestMeter"

FIXTURE_TEMPLATE: dict[str, Any] = {
    "name": "Acme Test Meter",
    "description": "Fixture template for unit tests",
    "connection": {
        "type": "RTU",
        "rtu_baud": "2400",
        "rtu_bytesize": "8",
        "rtu_parity": "N",
        "rtu_stopbits": "1",
        "unit": 1,
        "timeout": 3.0,
    },
    "registers": [
        {
            "name": "Voltage",
            "kind": "input_registers",
            "address": 0,
            "count": 2,
            "format": "f32",
            "unit": "V",
        },
        {
            "name": "Current",
            "kind": "input_registers",
            "address": 6,
            "count": 2,
            "format": "f32",
            "unit": "A",
        },
        {
            "name": "Total active energy",
            "kind": "input_registers",
            "address": 342,
            "count": 2,
            "format": "f32",
            "unit": "kWh",
        },
        {
            "name": "Total reactive energy",
            "kind": "input_registers",
            "address": 344,
            "count": 2,
            "format": "f32",
            "unit": "kvarh",
        },
    ],
}

SECOND_FIXTURE_RESOURCE = "Beta/Other.json"
SECOND_FIXTURE_TEMPLATE: dict[str, Any] = {
    "name": "beta other",
    "description": "",
    "connection": {"type": "TCP", "host": "127.0.0.1", "port": 502, "unit": 1},
    "registers": [{"name": "x", "kind": "holding_registers", "address": 0, "count": 1}],
}


def write_cloud_cache(path: Path, *entries: tuple[str, dict[str, Any]]) -> None:
    payload = {resource: data for resource, data in entries}
    path.write_text(json.dumps(payload), encoding="utf-8")


def seed_primary_cloud_cache(path: Path) -> None:
    write_cloud_cache(path, (FIXTURE_RESOURCE, FIXTURE_TEMPLATE))

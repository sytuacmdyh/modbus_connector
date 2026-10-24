"""File logger lifecycle for the desktop bridge; uses the existing writer."""

from __future__ import annotations

import time
from datetime import UTC, datetime
from typing import Any

from .datalogger import DataLogger, LogSample, LogSettings
from .flutter_registers import bounded, evaluate_expressions, render, row_from_json


class FlutterLogger:
    def __init__(self) -> None:
        self.writer = DataLogger()
        self.rows: list[dict[str, Any]] = []
        self.expressions: list[dict[str, Any]] = []
        self.interval = 1.0
        self.last = float("-inf")
        self.format = "csv"

    def close(self) -> None:
        self.writer.close()

    def dispatch(self, data: dict[str, Any]) -> dict[str, Any]:
        command = data["command"]
        if command == "logger_start":
            path = data.get("path")
            fmt = data.get("format", "csv")
            rows = data.get("rows")
            expressions = data.get("expressions", [])
            if not isinstance(path, str) or not path.strip() or fmt not in ("csv", "jsonl"):
                raise ValueError("Choose a file path and csv/jsonl format")
            if (
                not isinstance(rows, list)
                or not isinstance(expressions, list)
                or not 1 <= len(rows) + len(expressions) <= 512
                or any(
                    not isinstance(e, dict)
                    or not isinstance(e.get("name"), str)
                    or not isinstance(e.get("text"), str)
                    for e in expressions
                )
            ):
                raise ValueError("Select 1..512 rows to log")
            parsed = [row_from_json(row) for row in rows]
            interval = bounded(data.get("interval_ms", 1000), "interval_ms", 100, 86400000)
            append = data.get("append", True)
            fields = data.get("fields", ["timestamp", "name", "address", "kind"])
            if (
                type(append) is not bool
                or not isinstance(fields, list)
                or any(f not in ("timestamp", "name", "address", "kind") for f in fields)
            ):
                raise ValueError("Invalid logger settings")
            self.close()
            settings = LogSettings(path, fmt, frozenset(fields), append, interval)
            labels = [f"{row.name or row.kind}@{row.address}/u{row.unit_id}" for row in parsed]
            labels.extend(f"fx {e['name']}" for e in expressions)
            self.writer.open(settings, columns=labels if fmt == "csv" else None)
            self.rows = rows
            self.expressions = expressions
            self.interval = interval / 1000
            self.last = float("-inf")
            self.format = fmt
        elif command == "logger_sample":
            if not self.writer.is_open:
                raise ValueError("Logger is not running")
            values = data.get("values")
            if not isinstance(values, list) or len(values) != len(self.rows):
                raise ValueError("Sample does not match logger columns")
            cells = []
            for descriptor, raw in zip(self.rows, values, strict=True):
                row = row_from_json(descriptor)
                if (
                    not isinstance(raw, list)
                    or len(raw) != row.count
                    or any(type(v) not in (int, bool) or not 0 <= v <= 65535 for v in raw)
                ):
                    raise ValueError("Invalid raw sample")
                cells.append((row, render(row, raw, descriptor)["display"]))
            expression_results = evaluate_expressions(
                {"expressions": self.expressions, "values": data.get("expression_values", {})}
            )["rows"]
            now = time.monotonic()
            if now - self.last >= self.interval:
                stamp = datetime.now(UTC).isoformat(timespec="milliseconds")
                if self.format == "csv":
                    self.writer.write_snapshot(
                        stamp,
                        [display for _, display in cells]
                        + [e["display"] for e in expression_results],
                    )
                else:
                    for row, display in cells:
                        self.writer.write(
                            LogSample(stamp, row.name, row.address, row.kind, display)
                        )
                    for index, (expression, result) in enumerate(
                        zip(self.expressions, expression_results, strict=True)
                    ):
                        self.writer.write(
                            LogSample(
                                stamp, expression["name"], index, "expression", result["display"]
                            )
                        )
                self.writer.flush()
                self.last = now
        elif command == "logger_stop":
            self.close()
        elif command != "logger_status":
            raise ValueError("Unknown logger command")
        return {
            "active": self.writer.is_open,
            "rows_written": self.writer.rows_written,
            **({"expressions": expression_results} if command == "logger_sample" else {}),
        }

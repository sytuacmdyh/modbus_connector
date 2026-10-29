"""Фоновое логирование опрошенных значений в файл (CSV / JSON Lines); без Qt."""

import csv
import json
from dataclasses import dataclass, field
from typing import IO, Literal, get_args

LogFormat = Literal["csv", "jsonl"]
LogField = Literal["timestamp", "name", "address", "kind"]
LOG_FIELDS: tuple[LogField, ...] = get_args(LogField)


@dataclass
class LogSettings:
    path: str = ""
    format: LogFormat = "csv"
    fields: frozenset[LogField] = field(default_factory=lambda: frozenset(LOG_FIELDS))
    append: bool = True
    interval_ms: int = 1000


@dataclass
class LogSample:
    timestamp: str  # wall clock ISO 8601 with milliseconds, from the caller
    name: str
    address: int
    kind: str
    value: str


class DataLogger:
    """Пишет LogSample в файл: CSV (строки через csv-модуль) или JSON Lines
    (по объекту на строку — удобно читать потоково и дописывать в конец)."""

    def __init__(self) -> None:
        self._file: IO[str] | None = None
        self._writer: csv.writer | None = None  # type: ignore[type-arg]
        self._settings: LogSettings | None = None
        self.rows_written = 0

    @property
    def is_open(self) -> bool:
        return self._file is not None

    def _columns(self) -> list[LogField]:
        assert self._settings is not None
        return [f for f in LOG_FIELDS if f in self._settings.fields]

    def open(self, settings: LogSettings, columns: list[str] | None = None) -> None:
        """Открыть файл (OSError пробрасывается вызывающему)."""
        header = (
            ["timestamp", *columns] if columns is not None
            else [*(f for f in LOG_FIELDS if f in settings.fields), "value"]
        )
        if settings.format == "csv" and settings.append and columns is not None:
            try:
                with open(settings.path, newline="", encoding="utf-8-sig") as existing:
                    previous = next(csv.reader(existing), None)
            except FileNotFoundError:
                previous = None
            if previous is not None and previous != header:
                raise ValueError("CSV columns differ; choose a new file or disable append")
        # ``utf-8-sig`` writes a BOM only at the beginning of a new stream.
        # Excel uses it to detect UTF-8 reliably when the file is opened by
        # double-click, while csv/jsonl readers still consume the same text.
        encoding = "utf-8-sig" if settings.format == "csv" else "utf-8"
        file = open(  # noqa: SIM115  # closed explicitly in close()
            settings.path, "a" if settings.append else "w", newline="", encoding=encoding
        )
        self._file = file
        self._settings = settings
        self.rows_written = 0
        if settings.format == "csv":
            self._writer = csv.writer(file, lineterminator="\n")
            if file.tell() == 0:  # a new/empty file gets a header, appends don't
                self._writer.writerow(header)

    def write_snapshot(self, timestamp: str, values: list[str]) -> None:
        """Write one time sample in the fixed column order supplied to open()."""
        if self._file is None or self._writer is None:
            return
        self._writer.writerow([timestamp, *values])
        self.rows_written += 1

    def write(self, sample: LogSample) -> None:
        if self._file is None or self._settings is None:
            return
        columns = self._columns()
        if self._settings.format == "csv":
            assert self._writer is not None
            self._writer.writerow([getattr(sample, f) for f in columns] + [sample.value])
        else:
            record = {f: getattr(sample, f) for f in columns}
            record["value"] = sample.value
            self._file.write(json.dumps(record, ensure_ascii=False) + "\n")
        self.rows_written += 1

    def flush(self) -> None:
        if self._file is not None:
            self._file.flush()

    def close(self) -> None:
        if self._file is None:
            return
        try:
            self._file.close()
        finally:
            self._file = None
            self._writer = None

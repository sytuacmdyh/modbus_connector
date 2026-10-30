# Modbus Connector

A Flutter desktop workbench for debugging Modbus buses and developing devices.
Windows and Linux are supported. Each independent tab runs as a Master,
Simulator, passive RTU Sniffer or Gateway, backed by its own asynchronous Dart isolate.
The desktop has no Python interpreter or backend subprocess.
Flutter is the sole desktop GUI; the former Qt application has been removed.

- Master register maps: grouped reads, polling, engineering-value writes,
  byte orders, scaling, units, enums/bits, expressions and alarms.
- TCP, serial RTU, RTU over TCP/UDP; unit/address scanners and raw traffic.
- Simulator expression rules; transparent gateways; passive RTU decoding.
- CSV import/export, snapshots, logging and native multi-series graph windows.
- Public/cloud templates and separate personal template histories.
- English/Chinese UI, theme and persisted disconnected workspaces.

See the [desktop guide](flutter_app/README.md) for setup, controls, packaging
and native integration tests, and [verification history](docs/FLUTTER_STATUS.md)
for platform/device acceptance limits.

## Run from source

Install Flutter 3.47.8 and the platform's native desktop toolchain. Python is
unnecessary for running or building the desktop application:

```bash
cd flutter_app
flutter pub get
flutter run -d linux  # Windows: flutter run -d windows
```

Select **Workspace → Local demo** for a loopback simulator. Hardware addresses
are zero-based PDU addresses. Serial RTU uses the bundled native libserialport;
TCP/UDP, Modbus framing, servers and application services run in Dart.

## Build and install

```bash
cd flutter_app
flutter build linux --release  # Windows: flutter build windows --release
```

Distribute the entire `build/linux/x64/release/bundle/` directory (Windows:
`build/windows/x64/runner/Release/`). It contains Flutter and native plugins,
with no Python bridge or runtime. The Windows installer retains the existing
`ModbusConnectorFlutter` identity and preserves data outside its directory.
The optional repository packaging scripts use Python as a development tool:

```bash
# From the repository root, to include separate CLI/MCP binaries:
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[dev,build]' -e ./mcp
./build.sh  # Windows: build.bat
# Windows with NSIS installed:
# .venv/Scripts/python.exe packaging/windows/build_installer.py
```

These write the desktop to `dist/ModbusConnectorFlutter/` and headless tools to
`dist-cli/`. Python CLI/MCP binaries are separate downloads; the GUI never starts
them. Linux packages use `packaging/linux/make_appimage.sh` and `make_deb.sh`.
[GitHub Releases](https://github.com/sytuacmdyh/modbus_connector/releases) provide
Windows/Linux desktop packages and separate CLI/MCP tools. Startup checks notify
about new stable releases. Registered Windows installations can download, verify,
install and restart; Linux/portable copies use manual downloads. There is currently
no macOS desktop runner.

## Data and migration

Flutter data stays in `~/.modbus_connector/flutter/` (override:
`MODBUS_FLUTTER_HOME`). Workspace autosave, custom template histories and cloud
cache retain their existing locations. Cloud credentials are stored separately;
password persistence is opt-in. Only public templates synchronize through WebDAV.
Legacy Qt JSON files can still be explicitly imported into disconnected Flutter
tabs. Import does not modify the original files.

## CLI and MCP

The Python package also provides `modbus-connector-cli` (equivalently,
`python -m modbus_connector`) for scripts and headless servers. The companion
[MCP server](mcp/README.md) exposes the same backends to agents.

Output is **JSON-first**: structured JSON (or NDJSON for streaming commands)
goes to stdout, diagnostics to stderr; `--text` switches to human-readable
output. Exit codes: `0` ok (including Ctrl+C of streaming commands),
`2` connection error/timeout, `3` Modbus exception from the device,
`4` bad arguments/input files. Every subcommand has a `--help` with working
examples.

```bash
# one-shot read / write
modbus-connector-cli read --tcp 192.168.1.10:502 --unit 1 hr 200 6 --format f32
modbus-connector-cli write --rtu /dev/ttyUSB0 --baud 9600 coil 3 1

# polling: NDJSON stream to stdout and/or a CSV/JSONL log file, Ctrl+C to stop
modbus-connector-cli poll --tcp 192.168.1.10 hr 0 10 --interval 1000 --log out.csv
modbus-connector-cli poll --tcp 192.168.1.10 --map "Eastron/SDM120 template export.json"

# scanners: unit ids / register address space
modbus-connector-cli scan units --rtu /dev/ttyUSB0 1-10
modbus-connector-cli scan addresses --tcp 192.168.1.10 --unit 1 hr 0-100

# headless device simulator (map = template/session JSON or table CSV)
modbus-connector-cli simulate --map device.json --tcp 1502

# headless gateway: listen side and target side accept tcp:/rtu:/rtuovertcp: specs
modbus-connector-cli gateway --listen tcp:5020 --target rtu:/dev/ttyUSB0,baud=9600 --units "1,5"

# passive RTU sniffer: decoded frames and values as NDJSON
modbus-connector-cli sniff --rtu /dev/cu.usbserial-1420 --baud 19200
```

## Development

```bash
.venv/bin/python -m pip install -e '.[dev,build]' -e ./mcp
.venv/bin/python -m pytest tests mcp/tests -q
cd flutter_app
flutter analyze
flutter test
dart test test_backend
```

The [backend contract](flutter_app/BACKEND_PROTOCOL.md) defines the Dart service
boundary. Desktop UI/services live in `flutter_app/`; the Python reference and
headless tools stay in `src/modbus_connector/`.
See [Git Flow](docs/GIT_FLOW.md) for release conventions.

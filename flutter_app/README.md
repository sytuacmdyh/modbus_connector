# Modbus Connector — Flutter desktop

Material 3 Windows/Linux client with independent Master, Simulator, Sniffer and
Gateway session tabs. Each tab owns a Qt-free Python subprocess over NDJSON;
closing a tab waits for its active transaction and releases its resources.
The PySide6 application remains available with its existing settings and packaging.

The master workspace uses **Register map / CSV / snapshots** for all read/write
operations: named rows, all Qt formats and byte orders,
scaling/units, engineering-value writes, bit/enum labels, grouped reads, per-row
poll intervals, expressions and alarms. Toolbar tools include unit/address
scanning, CSV/JSONL logging, multi-series graphs and advanced Modbus functions.
The top **Workspace** menu opens templates/history, cloud sync, update checks,
and workspace save/import/export. The mode picker changes the active session;
use New session to run a simulator or gateway alongside a master.

Flutter data lives in `~/.modbus_connector/flutter/` (Windows:
`%USERPROFILE%\.modbus_connector\flutter`). `MODBUS_FLUTTER_HOME` overrides it.
Workspace autosave restores disconnected tabs, maps and preferences; cloud
credentials are stored separately and saving the password requires opt-in.
Public templates reuse the bundled catalog; custom histories and cloud cache
are separate from Qt. English/Chinese UI and help are available from the top bar.

The minimum content size is **900×650 logical pixels**. The table and activity
log scroll independently; the workspace also scrolls when validation messages or
larger text need more room, preserving usable pane heights.

## Windows: prerequisites and development

Use a Windows x64 machine with Git, **Flutter 3.47.8 stable / Dart 3.13+**,
**Python 3.11+ x64**, and **Visual Studio 2022** with **Desktop development with
C++**, its MSVC toolchain, CMake and Windows 10/11 SDK. VS Code alone does not
supply the native toolchain. The full `windows/` runner, resource/icon, manifest,
CMake files and plugin registrant are checked in; do not regenerate them.

PowerShell, starting in the repository root:

```powershell
flutter config --enable-windows-desktop
flutter doctor -v
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e .
$env:MODBUS_PYTHON = (Resolve-Path .\.venv\Scripts\python.exe).Path
Set-Location flutter_app
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

Activation of a PowerShell virtual environment is unnecessary. If your Python
minor version differs, replace `-3.11` accordingly. No Qt, numpy or GUI Python
extras are needed. `MODBUS_PYTHON` must name the actual interpreter executable,
without embedded quotes or arguments. Paths with spaces work without a shell.
Keep that terminal open when launching the development client.

Choose **Workspace → Local demo** for an offline demonstration. It opens a
separate tab, connects a real loopback TCP simulator and polls six named rows
across all four Modbus areas every 500 ms. Signal A/B move continuously; open the
multi-series graph to inspect them. The scaled setpoint and counter are writable;
the switch has an On/Off selector, while the contact and signal rows are read-only.
Reconnect resets demo values. Closing the tab stops polling and its owned simulator.
Selecting Local demo in a device connection form also opens a separate demo tab,
preserving the original connection and map. Restored demo tabs stay disconnected
until Connect; an empty demo map receives the example rows automatically.

For hardware choose TCP (default port 502) or RTU (default transport). RTU accepts
an editable port dropdown (discovered ports with device descriptions, or manual
`COM3`/device paths), port refresh, an editable baud dropdown with common rates
from 300 to 921600 and custom input, 7/8 bits, N/E/O parity,
1/2 stop bits, unit 1–247 and timeout 0.1–60 s. All addresses are **0-based PDU**,
not 40001-style reference numbers. The connection's unit is the default for map
rows without their own unit and for advanced Modbus commands; an explicit row
unit takes precedence. Row shortcuts change a raw unsigned 16-bit
register or coil. The register map also supports multi-register engineering-value writes with inverse
scaling and byte-order encoding. Disconnect gates controls immediately and waits for the active
transaction; Cancel connection uses the same path. The timeout includes the
existing backend's retries, so disconnection may take several device timeouts.

## Windows: release bundle without a Python installation

In the same PowerShell terminal, from `flutter_app/`:

```powershell
flutter build windows --release
& $env:MODBUS_PYTHON -m pip install pyinstaller
& $env:MODBUS_PYTHON .\tool\build_bridge.py --bundle .\build\windows\x64\runner\Release
Remove-Item Env:MODBUS_PYTHON -ErrorAction SilentlyContinue
.\build\windows\x64\runner\Release\modbus_desktop.exe
```

`build_bridge.py` must run **on Windows using Windows Python of the matching
architecture**. It freezes an onedir console bridge (pipes carry its stdio),
excludes Qt/numpy, and adds `bridge/modbus_bridge.exe` plus `bridge/_internal/`
beside the Flutter executable. It never changes existing Python packaging.
Re-run it after rebuilding Flutter. Distribute the **entire Release directory**,
including `data/`, Flutter/plugin DLLs and `bridge/`; the EXE alone is insufficient.
The target may need the Microsoft Visual C++ 2015–2022 x64 Redistributable. This
build produces a portable directory. To wrap it in an independent per-user
installer (NSIS must be installed), run from the repository root:

```powershell
.venv/Scripts/python.exe packaging/windows/build_installer.py --flutter `
  --bundle flutter_app/build/windows/x64/runner/Release --version 0.16.0+6
.venv/Scripts/python.exe flutter_app/tool/verify_windows_bundle.py `
  --bundle flutter_app/build/windows/x64/runner/Release
```

The installer uses `ModbusConnectorFlutter` for its installation directory,
uninstall registration and shortcuts. It preserves the Qt installation and all
settings outside its directory. It is not code signed. The verification script
starts the frozen bridge from an unrelated directory without a Python override,
uses separate simulator/master processes and isolated temporary data, and checks
read/write, traffic, expressions, logging, templates and EOF cleanup.

Bridge lookup order: runtime `MODBUS_PYTHON`, compile-time
`--dart-define=MODBUS_PYTHON=...`, adjacent frozen `bridge/modbus_bridge[.exe]`,
then `python` on Windows / `python3` on Linux with the package installed. For a
portable release, do not embed a developer's absolute Python path. The frozen
bridge is found relative to the running executable, independent of working
directory. Test the copied release directory from Explorer on a Windows machine
without Python; exercise Local demo, TCP, real COM hardware, high DPI, and window
close during a poll. Windows compilation/runtime and physical RTU require a
Windows/hardware validation pass; they cannot be verified on Linux.

## Linux

Install Flutter, Python 3.11+, and the native toolchain. Debian/Ubuntu example:

```bash
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev
# From the repository root:
python3 -m venv .venv
.venv/bin/python -m pip install -e .
export MODBUS_PYTHON="$PWD/.venv/bin/python"
cd flutter_app
flutter config --enable-linux-desktop
flutter pub get
flutter run -d linux
```

Serial ports usually require membership in the distribution's serial-access
group (often `dialout`) and a new login. The desktop needs a graphical session.

```bash
flutter analyze
flutter test
flutter build linux --release
# Optional portable Python bridge, from flutter_app/:
"$MODBUS_PYTHON" -m pip install pyinstaller
"$MODBUS_PYTHON" tool/build_bridge.py --bundle build/linux/x64/release/bundle
unset MODBUS_PYTHON
./build/linux/x64/release/bundle/modbus_desktop
```

Freezing needs Python's shared library (for system Python, install the matching
`libpython3.x` package; a uv-managed CPython also works). Build on the oldest
Linux distribution you intend to support because native libraries require a
compatible glibc. Ship the entire `bundle/` directory. Native GTK and platform
runtime libraries are still required.

## Tests and protocol

From the repository root, with Python `pytest` installed:

```bash
.venv/bin/python -m pytest tests/test_flutter_bridge.py tests/test_flutter_online.py tests/test_backend.py tests/test_backend_serial.py
```

From `flutter_app/`, the desktop integration test opens a real window and starts
the actual Python bridge plus simulator. On Linux without a display:

```bash
export MODBUS_PYTHON="$PWD/../.venv/bin/python"
export MODBUS_FLUTTER_HOME="$(mktemp -d)"
xvfb-run -a flutter test integration_test/desktop_test.dart -d linux
xvfb-run -a flutter test integration_test/parity_test.dart -d linux
```

On Windows, retain `$env:MODBUS_PYTHON` and use
`flutter test integration_test/desktop_test.dart -d windows`. Unit/widget tests
use a fake transport to exercise cancellation, polling, layout and editing; this
first integration test validates real process transport, all writable areas,
10 Hz polling, the chart, error recovery, reconnect and shutdown. The parity
test additionally covers separate simulator/master processes, expression rules,
grouped map reads, snapshots, logging, templates and persistence. Run these
files separately: one combined Linux invocation failed while launching its
second native app; both standalone commands passed. Protocol details and
resource lifecycle are in [BRIDGE_PROTOCOL.md](BRIDGE_PROTOCOL.md).

Windows frame-time regression (Profile mode, real bridge, 248 independent rows,
2 ms response pacing, full 1000-point histories, scrolling and resize):

```powershell
flutter drive --driver=test_driver/performance_driver.dart --target=integration_test/performance_test.dart -d windows --profile
```

Keep `MODBUS_PYTHON` set to the installed Python environment. The JSON report is
written to `build/integration_response_data.json`. Profile builds avoid debug
instrumentation skew; this benchmark also caps UI notifications per read cycle.

## Current parity limits

Desktop file operations use native choosers with editable-path fallback on
unsupported hosts. The named map is embedded directly below the connection settings; its
toolbar button scrolls to it. Map and sniffer column widths/order persist; drag
headers or their edges, or use the header movement/reset menu. That menu also
hides/restores columns and switches compact row height, with all preferences
persisted per session.
The map has one selection checkbox column: hold the left mouse button and sweep
along it to invert each crossed row once. Moving to the top/bottom edge continues
selection while the table scrolls. This changes selection only. Use the toolbar's
Enable polling / Disable polling buttons to change polling for the selected rows
(also available in the row context menu and Selected rows menu);
disabled rows show a pause marker beside their names. Existing polling flags are
preserved when opening an older workspace; its removed polling column is ignored.

Map polling stops
with the session connection. Device-mode serial forms include port discovery and
manual entry. Sniffer views support filters, hiding/restoring and per-unit graphs;
simulator rules offer keyboard prefix completion. Settings groups language, theme,
autosave and workspace files. With autosave off, use Save workspace to persist
preferences. Scanner results restore with the workspace. Graphs export PNG and CSV;
hover selects the nearest timestamp and click pins the cursor. Graph selection,
normalization and time window persist. Open separate window creates an owned
native graph viewer without another bus connection; closing the session closes
its viewers. The master toolbar opens raw TX/RX traffic with direction/hex
filters, display pause, copy/export and cumulative communication statistics.
Map context actions provide raw zero/one/increment/decrement/toggle and trend
controls; Ctrl+C copies display, Ctrl+0/1/+/−/T performs the corresponding raw
action on one selected writable row. Templates have manufacturer/name search.
Activity logs support filtering, errors only, copy and export. Settings and the
workspace menu explicitly import a Qt JSON configuration into disconnected
Flutter tabs, preserving the original file and separate Qt data.
Translation of unrecognized external diagnostics remains incomplete.

Update checking and manual download are wired. Automatic Flutter installation
is unavailable on every platform: the existing NSIS asset installs the Qt product.
Windows x64 build, installation, native integration and installed release UI
were verified on 2026-10-24. Physical COM, multi-monitor DPI and audio audibility
still require hardware verification.
See [FLUTTER_STATUS.md](../docs/FLUTTER_STATUS.md) for the detailed feature and
validation inventory, including hardware and UI gaps.

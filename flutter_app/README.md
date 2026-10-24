# Modbus Connector — Flutter desktop

Material 3 Windows/Linux client with independent Master, Simulator, Sniffer and
Gateway session tabs. Each tab owns a Qt-free Python subprocess over NDJSON;
closing a tab waits for its active transaction and releases its resources.
The PySide6 application remains available with its existing settings and packaging.

The master workspace provides a quick contiguous range and a richer **Register
map / CSV / snapshots** tool: named rows, all Qt formats and byte orders,
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

Choose **Local demo → Connect → Read** for an offline demonstration that uses the
real backend and a loopback TCP simulator. Select **Input registers · 04**, set
**100 ms**, then **Start polling** for a moving chart. Holding addresses 0–124 are
writable and initially contain 100–224; coils are also writable. Click a row to
chart it; use its pencil button to write (decimal or `0x` hex). Enter in a
connection field connects; Escape cancels a dialog. Errors stop polling; Read
retries, or Disconnect then Connect starts a fresh connection.

For hardware choose TCP (default port 502) or RTU (default transport). RTU accepts
manual `COM3`/device paths, port discovery, custom baud, 7/8 bits, N/E/O parity,
1/2 stop bits, unit 1–247 and timeout 0.1–60 s. All addresses are **0-based PDU**,
not 40001-style reference numbers. Quick-range writes change a raw unsigned 16-bit register or coil. The named
register map also supports multi-register engineering-value writes with inverse
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
build produces a portable directory, without an installer or code signing.

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

## Current parity limits

Desktop file operations use native choosers with editable-path fallback on
unsupported hosts. The named map is embedded below the master quick view; its
toolbar button scrolls to it. Map and sniffer column widths/order persist; drag
headers or their edges, or use the header movement/reset menu. Map polling stops
with the session connection. Device-mode serial forms include port discovery and
manual entry. Sniffer views support filters, hiding/restoring and per-unit graphs;
simulator rules offer keyboard prefix completion. Settings groups language, theme,
autosave and workspace files. With autosave off, use Save workspace to persist
preferences. Scanner results restore with the workspace. Graphs export PNG and CSV;
hover selects the nearest timestamp and click pins the cursor. Additional Qt
display/view conveniences, detached graph windows and translation of unrecognized
external diagnostics remain deferred.

Update checking and manual download are wired. Automatic Flutter installation
is unavailable on every platform: the existing NSIS asset installs the Qt product.
Windows runtime/high-DPI/physical COM checks remain a user verification step.
See [FLUTTER_STATUS.md](../docs/FLUTTER_STATUS.md) for the detailed feature and
validation inventory, including hardware and UI gaps.

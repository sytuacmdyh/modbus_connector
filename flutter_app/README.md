# Modbus Connector — Flutter desktop

Windows/Linux workbench with independent Master, Simulator, passive RTU Sniffer
and Gateway tabs. Each tab owns an asynchronous Dart isolate in the application;
there is no Python interpreter or backend subprocess. Serial ports use a bundled
native libserialport plugin. Separate native graph windows receive graph data
without opening additional bus connections.

The desktop preserves register maps, all formats and byte orders, scaling,
engineering writes, enums/bits, expressions, alarms, scanners, CSV/JSONL logging,
snapshots, template histories and WebDAV. Legacy Qt JSON import remains explicit.
Flutter state stays in `~/.modbus_connector/flutter/` (override:
`MODBUS_FLUTTER_HOME`); cloud credentials stay separate with opt-in password saving.
The minimum content size is 900×650 logical pixels.

## Development

Use Flutter **3.47.8 / Dart 3.13+**. Windows also requires Visual Studio 2022
Desktop development with C++, CMake and Windows SDK. Linux requires a graphical
session, clang, CMake, Ninja, pkg-config and GTK development headers:

```bash
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev
cd flutter_app
flutter pub get
flutter analyze
flutter test
dart test test_backend
flutter run -d linux  # Windows: -d windows
```

Python, a venv and `MODBUS_PYTHON` are unnecessary. Linux serial access may
require membership in `dialout` and a new login. Serial settings support manual
ports/discovery, custom baud rates, 7/8 bits, N/E/O parity and 1/2 stop bits.
Addresses are zero-based PDU addresses, units 1–247 and timeouts 0.1–60 s.

Choose **Workspace → Local demo** to create an isolated tab with a real loopback
TCP simulator and six polling rows. Writes affect the simulator; reconnect resets
it. Closing its tab releases the simulator. No hardware is needed.

## Packaging

```bash
flutter build linux --release  # Windows: flutter build windows --release
```

Distribute the **entire** `build/linux/x64/release/bundle/` directory or Windows
`build/windows/x64/runner/Release/`, including data and plugin libraries.
The application contains no `bridge/` directory or Python runtime. Remove stale
bridge folders when reusing an output directory from the former Python build.
Linux needs compatible GTK/glibc; Windows may need the Visual C++ Redistributable.
Serial library notices and LGPL source links ship in `assets/licenses/`.

Repository `build.sh` / `build.bat` also package separate Python CLI/MCP binaries
and therefore use a development Python environment. They write the Flutter bundle
to `dist/ModbusConnectorFlutter/`. The Windows NSIS wrapper is a development tool:

```powershell
.venv/Scripts/python.exe packaging/windows/build_installer.py
```

It produces `modbus-connector-flutter-<version>-windows-x64-setup.exe`, preserves
the existing Flutter install/uninstall/shortcut identity and rejects bundles
containing a Python bridge/runtime. It does not uninstall a former Qt product.
The GUI checks for stable updates on startup by default (Settings can disable it).
Workspace → Check for updates also checks immediately. A registered Windows
Flutter installation can download, verify and install its matching x64 NSIS asset.
The confirmation explicitly saves the workspace even when autosave is off, closes
all sessions/graph windows, then exits. A separate PowerShell helper waits for
process exit, installs into the registered directory and restarts the app. Download
cancellation and failed verification leave the running app unchanged. Size, SHA-256
and executable-header checks precede handoff; redirects are limited to GitHub asset
hosts. Portable/source copies and Linux keep manual downloads. No Python is used.

## Verification and backend contract

```bash
flutter analyze
flutter test
dart test test_backend
# Each integration file starts a native desktop window; run separately:
flutter drive --driver=test_driver/native_driver.dart --target=integration_test/desktop_test.dart -d linux --profile
flutter drive --driver=test_driver/native_driver.dart --target=integration_test/parity_test.dart -d linux --profile
# Headless Linux: prefix each command with xvfb-run -a
```

Unit/widget tests cover interface state, editing and cancellation. Native backend
tests exercise sockets, framing, simulator/gateway lifecycle, WebDAV, logging,
histories and Python-derived numerical fixtures. The independent Python tests
remain useful as a reference and for CLI/MCP; they are not desktop dependencies:

```bash
.venv/bin/python -m pytest tests mcp/tests
```

[BACKEND_PROTOCOL.md](BACKEND_PROTOCOL.md) describes the in-process request/result
contract. Python reference adapters retain the old NDJSON protocol for comparison.
Physical serial devices, Windows installation and DPI require platform acceptance;
local tests do not establish electrical or hardware compatibility.

## Current parity limits

Desktop file operations use native choosers with editable-path fallback on
unsupported hosts. The master map fills the height below a compact connection
summary. Connection settings opens a dialog for transport, serial/network parameters,
unit and timeout; Apply validates and saves, Cancel discards edits. Connect uses the
saved parameters and opens settings when required values are missing. Activity lives
in a collapsible right panel on wide windows; narrower windows open it in a right
drawer. Session tools contains traffic, logging, scanning, diagnostics and appearance.
Read/Poll map, interval, Add row and filtering remain visible. More tools expands
grouping, graphs, expressions, CSV and snapshots. Selected-row actions appear in a
floating bottom bar, with room to scroll the last row clear of it; the table viewport
stays fixed during sweep selection. Map and sniffer column widths/order persist; drag
headers or their edges, or use the header movement/reset menu. That menu also
hides/restores columns and switches compact row height, with all preferences
persisted per session.
The master map defaults to 48 px compact rows with Area, Count and Unit hidden.
Saved visibility and density preferences take precedence; Reset columns restores
these defaults, and the header menu can show any hidden column again.
The filter bar combines case-insensitive name matching, a zero-based address or
start-count range (decimal or `0x` hex; `100-20` covers 100–119), polling status and function area. Address
filters include rows whose register spans overlap the range. The address field's
arrow opens shortcuts derived from the current map: each occupied 100-address
page is trimmed to its actual covered span (e.g. 1000–1099 becomes `1001-66`
when the occupied addresses run from 1001 through 1066). Empty pages are omitted;
crossing rows contribute to both pages. Choosing a shortcut preserves the other
filters; All addresses clears only the address filter. The count shows
visible/total rows; Clear filters restores the full map. Filters only affect the
view: Read map/Start polling, CSV exports and snapshots still use the whole map as
before. Changing a filter clears selection; select-all and batch actions affect
only visible selected rows, and movement skips hidden rows.
The map has one selection checkbox column: hold the left mouse button and sweep
along it to invert each crossed row once. Moving to the top/bottom edge continues
selection while the table scrolls. This changes selection only. Use the contextual bottom bar's
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

Startup and manual stable-release checks are wired. Registered Windows Flutter installations support verified download, installation and restart; Linux/portable copies use manual downloads.
The former Python-backed Windows UI was verified on 2026-10-24.
The Dart migration has passed Windows release startup and both native profile integration files. Installation/upgrade and hardware acceptance remain separate. Physical COM, multi-monitor DPI and audio audibility
still require hardware verification.
See [FLUTTER_STATUS.md](../docs/FLUTTER_STATUS.md) for the detailed feature and
validation inventory, including hardware and UI gaps.

Map polling: **Start polling** keeps value, enum and bit writes available while
reading. Writes wait for the current read request and run serially; recoverable read
or write errors are logged without stopping polling. Disconnecting stops polling.
The progress animation is hidden during polling. Row trends default to disabled;
use **Enable trend** on selected rows to collect and show history.

During polling, structural editing tools keep a stable disabled state; selection
and value writes remain available. Raw value changes highlight only the current
value cell in amber for three seconds; repeated identical reads do not extend it.

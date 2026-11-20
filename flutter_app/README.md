# Modbus Connector — Flutter desktop

Windows/Linux workbench with a macOS host under native acceptance, and independent Master, Simulator, passive RTU Sniffer
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

### macOS local build (under acceptance)

The macOS host targets macOS 12 or newer. Install full Xcode (Command Line
Tools alone are insufficient), CocoaPods and GNU autoconf/automake/libtool
(`glibtoolize` on PATH) for the serial plugin. Run
`bash tool/build_macos.sh` from this directory. Set `FLUTTER_BIN` to a Flutter
executable path if it is not on PATH. The script builds Release and rejects
any Mach-O executable/library missing either arm64 or x86_64, then checks the
bundle's code signature. It does not publish or install the result.

The output is `build/macos/Build/Products/Release/Modbus Connector.app`.
This local build is not notarized. It intentionally runs outside App Sandbox
to retain the established data directory, direct serial access, file operations,
and graph subprocesses. Physical serial and both CPU architectures still require
native acceptance.

`bash tool/package_macos.sh` also creates a local
`modbus-connector-flutter-<version>-macos-universal.dmg` and checksum file under
`build/macos/`, without publishing. The source package version is passed to Dart
and the native bundle. macOS updates recognize that exact asset name and require
a SHA-256-bearing asset in GitHub Releases. Automatic installation is available
only for `Modbus Connector.app` in a writable `/Applications` or `~/Applications`.
Downloads are verified before read-only mounting; the bundle identity, version,
signature and both CPU architectures are checked before staging. Replacement
waits for explicit confirmation and application exit. A launch failure rolls back;
the previous bundle remains in the adjacent `.modbus-update-*` directory for
manual recovery. Automatic update mechanism tests use temporary signed fixtures;
the installed Flutter application still needs end-to-end acceptance.

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
flutter drive --driver=test_driver/native_driver.dart --target=integration_test/register_workspace_test.dart -d linux --profile
# macOS: replace -d linux with -d macos; run each file separately.
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
saved parameters and opens settings when required values are missing. The collapsible
bottom console groups Activity (first, selected by default) and Bus traffic (second)
in tabs, initially folded on shorter windows. Switching tabs keeps the map viewport
unchanged and preserves each tab’s filters and the traffic display pause. Bus traffic
provides TX/RX and hex filtering, pause/resume, copy, export, clear and bus statistics;
capture continues while either tab is hidden, retaining the latest 10,000 chunks.
TX/RX chunks stream immediately from the backend, including while waiting for
responses or timeouts. Flutter coalesces painting on render frames without waiting
for command completion. Traffic refreshes independently of register-map cycle publication and follows the
latest frames when at the bottom; scrolling back preserves the history position.
Traffic tools and filters occupy one compact row at the right of the console title.
Drag the divider above the console to resize it; tabs and collapse/expand preserve
the chosen height for this window, with bounds that leave map space available. The status
strip shows live connection/polling state and bus counters without resizing when
values change. Session tools contains logging, scanning, diagnostics and appearance.
Read/Poll map, interval, Add row and filtering remain visible. More tools expands
graphs, expressions, CSV and snapshots. Selected-row actions appear in a
floating bottom bar, with room to scroll the last row clear of it; the table viewport
stays fixed during sweep selection. Map and sniffer column widths/order persist; drag
headers or their edges, or use the header movement/reset menu. That menu also
hides/restores columns, with preferences persisted per session.
The master workspace has a read-only overview on the left and the editable map
on the right. Drag the divider to resize; the split is saved per session. Narrow
windows stack the panes. Configure display adds, renames, orders and hides blocks,
selects registers and sets ordered numeric range colors. Blocks have no icons;
values and engineering units share compact rows. The overview consumes the same
published results as the table and never starts acquisition. Its display colors do
not trigger logging or sound. Configuration travels with workspaces and custom
templates; stable row IDs preserve references when rows are moved or edited.
The master map defaults to 34 px rows and only Select, Address, Name, Engineering
value (with unit) and Actions columns. Columns and header menus restore optional
columns and Reset columns restores defaults. Saved column and 48 px comfortable
row preferences still take precedence; the master map offers no row-height toggle.
Clicking a writable engineering value opens its write dialog.
The compact filter bar combines case-insensitive name matching, a zero-based address
or start-count range (decimal or `0x` hex; `100-20` covers 100–119), access
(Writable / All access / Read-only, default Writable) and polling status. There is
no function-area filter. Address
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

The Engineering value column always shows the formatted read result, including
the configured data type, byte order, scaling and value/bit names. Unread rows show
an em dash. Click a writable value to open its numeric, enum or bit editor; enum
choices write raw values without applying engineering scaling.

Template/register rows can set `writable: false` for device fields that are read
through FC03 but cannot be written. Their area remains `holding_registers`.
The row editor's **Allow writes** checkbox is editable while disconnected;
input/discrete areas are always read-only. A lock marks read-only rows, and all
numeric, enum, bit and quick write actions are disabled. The backend checks access
and row bounds again before sending a row write. Reads, polling, trends and logging
continue normally. Omitted `writable` retains the old area-based behavior; explicit
values must be booleans, and `true` on input/discrete areas is invalid. Permissions
survive template versions, workspace saves and CSV export/import (`true`/`false`,
blank means omitted). Split rows if access differs within a contiguous range.
Older clients may ignore this field; raw CLI/MCP address operations are independent
of the desktop map's permissions.

Map polling stops
with the session connection. Device-mode serial forms include port discovery and
manual entry. Sniffer views support filters, hiding/restoring and per-unit graphs;
simulator rules offer keyboard prefix completion. The default language is Simplified
Chinese; the top toolbar displays the current language and offers a direct Chinese/
English switch. Saved language preferences take precedence over the default.
Settings groups theme, autosave and workspace files. With autosave off, use Save
workspace to persist preferences. Scanner results restore with the workspace. Graphs export PNG and CSV;
hover selects the nearest timestamp and click pins the cursor. Graph selection,
normalization and time window persist. Open separate window creates an owned
native graph viewer without another bus connection; closing the session closes
its viewers. The bottom Bus traffic tab displays raw TX/RX traffic with direction/hex
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
Read timeout activity entries include the transport/endpoint, unit, function code,
zero-based address, count and configured timeout. Each session logs the first
timeout immediately, then at most once every five seconds across all read ranges.
The next timeout entry summarizes additional timeouts since the previous entry
and shows the latest failed request (including an individual grouped-read fallback).
Successful reads do not reset this limit; clearing activity or reconnecting does.
The progress animation is hidden during polling. Row trends default to disabled;
use **Enable trend** on selected rows to collect and show history.

During polling, structural editing tools keep a stable disabled state; selection
and value writes remain available. Raw value changes highlight only the current
value cell in amber for three seconds; repeated identical reads do not extend it.

### Diagnostic logs and native crashes

The Activity panel has **Export crash logs** and **Clear logs** buttons. Application
startup, connection lifecycle, session errors, Flutter errors and worker failures
are persisted under `~/.modbus_connector/flutter/logs` (honoring
`MODBUS_FLUTTER_HOME`). Each isolate uses its own flushed JSONL file; files rotate
at 2 MiB with one previous segment, retaining at most 32 application log files.
Command payloads and saved cloud configuration are not included.

Export creates a ZIP off the UI isolate containing retained application logs,
available `%LOCALAPPDATA%/CrashDumps/modbus_desktop.exe*.dmp` files, and a snapshot
of this application's Windows Application Error/WER events from the last 14 days.
Missing or inaccessible Windows evidence is noted in `README.txt`; native dump
availability depends on Windows crash reporting. Dumps can contain process memory.
Clearing requires confirmation, deletes only this application's saved logs/dumps
and clears the current activity view. It preserves settings, templates, data logs,
previously exported ZIPs and Windows system events. New activity creates new logs.

Version 0.16.8 fixes serial disconnect heap corruption by leaving assigned
`SerialPortConfig` disposal to `SerialPort`, as required by the pinned
`libserialport 0.3.0+1` implementation (including setter failure).

### Stopping acquisition

Stop cancels the active register-map read through an out-of-band worker message,
releases the busy state, and prevents grouped-read fallback and later polling
requests. The port stays connected. Frames already sent cannot be recalled.
For RTU transports, restarting waits out the abandoned request's remaining
response deadline before sending another request, so a late reply cannot be
mistaken for the next response. Stop also interrupts this wait. Cancellation
does not count as a communication error and never targets an active value write.
## Browser build

The browser edition uses the shared Flutter workbench. It can run as static files
without a Dart or Python service. Local demo acquisition runs in memory; serial
RTU uses Web Serial after the user selects and authorizes a port. The page must
be served from HTTPS or localhost and the browser must support Web Serial.

```sh
flutter pub get
flutter build web --release --no-web-resources-cdn
```

Deploy the complete `build/web/` directory on a static web host (including local CanvasKit assets). For a subdirectory, pass the matching
`--base-href /your-path/`. During local testing, use any static HTTP server with
that directory as its root. No device connection occurs merely by opening or
restoring a workspace.

Workspace settings and custom template history are stored per browser origin;
changing host, port or browser profile changes the storage location. File import
uses the browser chooser; exports download a file. Browser storage is not a
backup, so export workspaces that need to be retained independently.

Browser logs use a 4 MiB in-memory segment. Stop and **Download log** before
closing the page or replacing a segment. Capacity errors preserve the old data.
UINT64/INT64 text display, engineering writes and CSV/log export preserve all
64 bits; graph, expression and numeric alarm calculations use floating point.

### Read-only WebDAV sync (desktop and web)

Choose **Workspace → WebDAV sync**. Both editions use the same read-only
protocol and consume the `.catalog.json` / `.versions/` snapshots published by
the `modbus-template-upload` skill. The application has no publisher mode,
upload button or server-version activation command. Old publisher settings
automatically behave as read-only settings. Local custom templates remain local.

Enter the WebDAV base URL, username/password if required, and **Templates path**.
For a skill upload target `https://example.com/dav/templates`, enter base URL
`https://example.com/dav` and path `templates`. **Test connection** checks WebDAV;
**Download current templates** validates the complete server catalog before
replacing the local public-template cache. Open downloaded configurations from
**Templates / history → Public (read-only)**; new tabs stay disconnected. History
downloads change the local cache only. Invalid data, authentication/network errors
and cancelled downloads preserve the previous cache. Legacy manufacturer/file
directories are still readable when the server has no `.catalog.json`.

Settings and cache use the existing Flutter data directory on desktop and
per-origin localStorage in the browser. **Save connection settings** stores the
password only when **Remember WebDAV password on this device** is enabled;
passwords stay separate from workspace exports. Downloaded templates remain
available after reload and while offline. Sync never replaces active sessions,
their current configuration or personal template histories.

The browser contacts WebDAV directly: no Dart communication service is needed.
Enabling or disabling that service does not change the UI's local catalog or
WebDAV settings. A remotely hosted HTTPS page needs an HTTPS WebDAV endpoint.
Cross-origin WebDAV must handle unauthenticated OPTIONS preflights and return
these headers on success **and error** responses (replace the example origin):

```text
Access-Control-Allow-Origin: https://modbus.example.com
Access-Control-Allow-Methods: GET, PROPFIND, OPTIONS
Access-Control-Allow-Headers: Authorization, Cache-Control, Content-Type, Depth
Vary: Origin
```

Alternatively, serve a WebDAV reverse proxy under the same origin as the page.
Use the canonical URL: redirects are rejected; DAV directory hrefs must match the
public URL and stay within the requested directory. Authentication errors and
CORS/TLS failures are shown in the dialog; the app does not fall back to a Dart
proxy. The static container continues to require no writable volume.

For local browser acceptance, start the synthetic read-only fixture in another
terminal with `dart run tool/webdav_fixture.dart`, then run:

```sh
flutter test --platform chrome test/web_workbench_test.dart
dart test --platform chrome --concurrency=1 test_backend/cloud_sync_test.dart test_backend/browser_cloud_sync_test.dart
```

The fixture uses only test data and a test account; it does not read skill
configuration or access a real WebDAV server. Native GUI acceptance can run
`integration_test/webdav_test.dart` independently using the existing driver.

### Docker image

The static web image is published to GitHub Container Registry:
`ghcr.io/sytuacmdyh/modbus_connector-web:latest` (Linux amd64 and arm64).
It contains Nginx and the compiled site, including CanvasKit. No Dart service,
Flutter SDK or Python runtime is required in the running container.

```sh
docker run -d --name modbus-connector-web --restart unless-stopped \
  -p 8080:8080 ghcr.io/sytuacmdyh/modbus_connector-web:latest
```

Open `http://localhost:8080/`. For other machines, put an HTTPS reverse proxy in
front of port 8080 when using Web Serial. The optional service is configured in
the browser Settings; its URL must be reachable from the user's browser. This
container does not start the service or access host serial devices.

The image runs as a non-root user and exposes `/healthz`. A read-only root
filesystem is supported by adding `--read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m`.
Nginx revalidates assets after upgrades and returns the correct WebAssembly MIME
type. Workspaces and templates remain in each browser's storage; no data volume
is required for the static server.

To build locally, first compile the site with Flutter 3.47.8, then run Docker
from the repository root:

```sh
cd flutter_app
flutter pub get
flutter build web --release --no-web-resources-cdn
cd ..
docker build -f Dockerfile.web -t modbus-connector-web:local .
```

The **Web image** workflow builds and tests the site and verifies HTTP responses
from the container before publishing. Changes to web sources on `main` publish
`latest`, `main`, the application version (for example `0.16.16`) and `sha-<commit>`
tags. `v*` release tags also publish the matching
semantic version and major/minor tags; prereleases do not replace `latest`.
Pull requests only validate. The workflow can also be run manually. Publishing
uses the repository's `GITHUB_TOKEN` with `packages: write`; no extra registry
secret is needed. For a new repository/fork, make its GHCR package public in the
package settings to allow anonymous pulls; source repository visibility alone
does not make a new package public.

### Optional Dart service

The default deployment needs no service. To enable TCP, RTU over TCP/UDP, remote
serial ports, simulator, sniffer and gateway, run the standalone host near those
devices. In the web UI choose **Settings → Optional Dart service**, enter its
WebSocket URL and access token, then **Test and apply**. This disconnects existing
sessions while retaining their configuration. Endpoint and token are memory-only;
reload returns to browser mode. Template and WebDAV UI operations always use the
client's local catalog, independently of this service. Existing service-side
templates remain in their separate service directory. The token grants access
to devices reachable by that host.

```sh
# From flutter_app/, with a matching native libserialport library:
export LIBSERIALPORT_PATH=/absolute/path/to/libserialport
# Optional: export MODBUS_SERVICE_TOKEN=<at-least-24-characters>
dart run bin/modbus_service.dart --origin http://localhost:8080
```

The default endpoint is `ws://127.0.0.1:18766/ws`. Without an environment token,
the CLI prints a generated token for that run. Repeat `--origin` for each exact
allowed browser origin (no trailing slash). The server binds loopback by default;
`--bind`, `--port` and `--data-dir` are explicit overrides. An HTTPS frontend
should use `wss://` through a TLS reverse proxy, forwarding WebSocket upgrades
and the original Origin. Browser local-network policies still apply. Never put
the token in the URL. Native clients authenticate too; they may omit Origin.

Each WebSocket owns one isolated backend. A disconnected or silent browser loses
its session and resources (45-second lease). Commands and uncertain writes are
never replayed. Service log files are confined to the session directory, stop at
20 MiB, and can be downloaded while that WebSocket remains open; cleanup removes
them when the session closes. Use filenames without directories. Installer,
cloud and internal worker commands are not exposed.

For a standalone executable without the Dart SDK on the destination:

```sh
dart run tool/package_service.dart /absolute/path/to/matching/libserialport
build/dart-service/start-service.sh --check-serial
build/dart-service/start-service.sh --origin http://localhost:8080
# Windows: build\dart-service\start-service.cmd
```

Distribute the complete `build/dart-service/` folder, including its native library
and LGPL notices. Build on the destination OS/architecture and provide matching
libserialport dependencies. macOS packaging/loading was verified locally;
Windows/Linux executable distribution and real hardware require separate checks.
See [adaptation details and acceptance](../docs/WEB_ADAPTATION.md).

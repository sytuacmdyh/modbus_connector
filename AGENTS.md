# Agent Guidance: modbus_connector

The only desktop GUI is Flutter in `flutter_app/`. Qt GUI modules, GUI Python
extras and GUI entry points were removed. The Python package remains for
independent headless CLI/MCP and as a behavioral reference; do not make it a
runtime dependency of the desktop.

Each Flutter session owns `NativeBridge` → `backend/NativeService` in a Dart isolate.
`wire.dart` provides serialized asynchronous TCP/RTU-over-TCP/UDP and a bundled
libserialport FFI adapter. `devices.dart` owns simulator, passive sniffer and
transparent gateway resources; `registers.dart` and `expression.dart` handle
formatting/encoding/grouping/alarms and safe expressions. `catalog.dart`,
`files.dart`, `online.dart` own templates/history/import, CSV/logging and WebDAV/
release checks. Preserve cancellation and late-result suppression in UI controllers.
All validation precedes external I/O; session close waits for owned resources.

Flutter state/custom history/cache stay under `~/.modbus_connector/flutter`
(`MODBUS_FLUTTER_HOME` override). Cloud password persistence is opt-in. Public
catalog publication requires publisher mode; local consumer checks precede HTTP.
Qt JSON import only reads original files and creates disconnected Flutter tabs.

Desktop build: `cd flutter_app && flutter build linux --release` (or windows).
No Python bridge, interpreter or `MODBUS_PYTHON` is used. Repository packaging
scripts also build independent Python CLI/MCP tools; do not put them in the GUI
bundle. Retain `ModbusConnectorFlutter` installer identity and data locations.

Checks: `flutter analyze`, `flutter test`; run each native integration file
separately with a graphical display. Python reference/CLI tests: `pytest tests
mcp/tests`. Keep source, host, Windows install and physical serial acceptance
claims distinct. LGPL libserialport notices live in `flutter_app/assets/licenses`.

See `flutter_app/README.md`, `flutter_app/BACKEND_PROTOCOL.md` and
`docs/FLUTTER_STATUS.md` for UI behavior and verification history.

Master acquisition and UI invariants:
- The register map is the sole read/write surface. Its virtualized table fills
  the remaining height; selected-row controls float without resizing its viewport.
- Connection edits use a validated modal draft. Connected/busy sessions lock
  structural editing. Polling keeps value/enum/bit writes and selection available;
  writes wait for the active read, without stopping polling. Recoverable errors
  are logged; disconnect stops acquisition. Publish changes at cycle boundaries.
- Filters affect the view only, preserving acquisition, CSV and snapshots.
  Map visible indices back to source rows for actions, selection and movement.
  Address A-N means A through A+N-1, matching overlaps within 16-bit bounds;
  presets derive occupied hundred-address pages from the entire current map.
- Trends require explicit trend_enabled=true; missing means disabled. Only raw
  value changes highlight the value cell for three seconds. Unchanged reads do
  not extend the highlight. Inactive tabs mute tickers without stopping I/O.
- Selection sweep tracking belongs to the viewport, including edge auto-scroll.
  Poll flags remain in row/batch menus. Input fields bypass map shortcuts.
- Each graph viewer owns only its sample pipe; it opens no Modbus connection.
  Session close waits for graph viewers and backend cleanup. File chooser dialogs
  use editable-path fallback. Workspace import stages disconnected tabs before
  replacing sessions and never writes the original legacy file.
- Preserve compact 48 px defaults with Area/Count/Unit hidden, saved column
  overrides and Reset columns. Settings autosave-off requires explicit Save.

`src/modbus_connector/__init__.py` remains the release version source for the
Python tools and packaging. Release bumps also update `flutter_app/pubspec.yaml`;
packaging passes APP_VERSION into the native build. Fixture regeneration is an
optional Python development step: `python flutter_app/tool/generate_backend_fixtures.py`.
The checked-in fixtures run without Python via `cd flutter_app && dart test test_backend`.

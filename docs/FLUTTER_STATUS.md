# Automatic update support (2026-10-30)

Startup stable-release checks are enabled by default and can be disabled in
Settings. Manual checks remain under Workspace. Registered Windows Flutter
installations support cancellable download, size/SHA-256/MZ validation and a
PowerShell install/restart handoff. Only the matching Flutter x64 NSIS release
asset is accepted; Qt installers are excluded. The install confirmation explicitly
saves workspace state, including with autosave off. Save/helper failure prevents
shutdown. Session and graph cleanup precedes process exit; the helper installs only
after both confirmation and exit. Linux and portable/source copies remain manual.

The real Windows PowerShell helper has been exercised against temporary mock
executables for confirmed install/restart and unconfirmed abort, including paths
with Chinese, spaces, apostrophes and dollar signs. This helper smoke test uses
mock executables; real installation acceptance is recorded below.

Validation: `flutter analyze` is clean, all 100 Flutter unit/widget tests and
379 backend tests pass, and `flutter build linux --release` succeeds. Coverage
includes installer selection, invalid redirects and payloads, download cancellation,
late handoff cancellation, explicit Save with autosave off, save/helper failures,
settings persistence, resource cleanup before exit and both Windows helper paths.

Release validation follow-up: Windows PowerShell child processes discard inherited
`PSModulePath` so apps launched from PowerShell 7 still load the Windows PowerShell
5.1 utility/CIM modules. The same launch environment is used by the helper smoke
tests. See Microsoft's [module-path guidance](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_psmodulepath).
The backend suite now has 380 tests. Linux native integration waits for the
workspace menu animation before selecting Local demo; both integration files pass
separately under Xvfb. Local WSL verification uses `LIBGL_ALWAYS_SOFTWARE=1` to
avoid a captured crash inside the host Intel GPU shader compiler. Linux GitHub CI
also passes both native files and AppImage/deb packaging checks.

Local Windows update acceptance (2026-10-30): rebuilt the Windows release from
this working tree, passed all 379 backend tests with Windows Dart, and produced
`modbus-connector-flutter-0.16.3-windows-x64-setup.exe` (9,915,371 bytes, SHA-256
`c16cf5b42151ec0f7227f4a2fdd8bdaa3e93fd9185dedd53bf2d7a4cc9aa4c3b`).
The NSIS installer updated the existing `ModbusConnectorFlutter` installation;
all 17 payload files match the build and all 42 existing user-data files were
bytewise unchanged through installation and isolated startup verification. The
installed window is responsive, with no Qt/Python runtime or backend child, and
has been started again using the normal user profile. The local version remains
0.16.3; this is not a new published release. Installation and user-data backups,
source hashes and logs are retained under the local build staging directory;
`dist/windows-update-20261030.json` records the paths and results. A future-release
automatic download-to-install upgrade and physical serial acceptance were not run.

The dated transition record below describes the earlier manual-only state.

# Flutter-only transition (2026-10-29)

The desktop now uses Flutter with an asynchronous Dart backend and a bundled
native libserialport plugin. Qt UI modules, GUI extras, Qt release paths and the
desktop Python bridge have been removed. Python is retained for the independent
CLI/MCP tools and behavioral reference tests. Template schemas, local histories
and explicit legacy JSON import remain compatible.
Windows NSIS packaging retains the ModbusConnectorFlutter identity and data paths.
Windows/Linux CI now builds Flutter by default. Updates remain manual because
this client has no automatic install handoff. macOS has headless tools only.

## Architecture and storage

Flutter calls the Dart `NativeService` directly through a `NativeBridge` and an owned Dart isolate; no
Python interpreter, NDJSON child or Qt runtime is part of the desktop. Each session
serializes transactions, validates ranges before I/O, cancels between read groups,
and suppresses late read/error/alarm effects. Disconnect and shutdown wait for
active I/O; TCP IDs reject late replies and RTU drains a timed-out transaction
before polling resumes. Template/cloud/update services share the same owned Dart
lifecycle. The request/result contract is documented in
[BACKEND_PROTOCOL.md](../flutter_app/BACKEND_PROTOCOL.md).

Flutter data uses `~/.modbus_connector/flutter` (Windows:
`%USERPROFILE%\.modbus_connector\flutter`), overridable with `MODBUS_FLUTTER_HOME`:

- `settings.json`: schema-1 workspace; sessions always restore disconnected.
- `custom_templates/`: personal version histories, separate from Qt histories.
- `cloud_templates.json`: validated, atomically replaced public catalog overlay.
- `cloud.json`: separate settings; password saved only with explicit opt-in.

Workspace exports and public cloud publication exclude cloud credentials. Cloud
transfers never replace sessions or personal templates. Consumer mode rejects
backend writes before network access; server permissions still apply.

## Current native verification

`flutter analyze` is clean. The 95 Flutter unit/widget tests, 367 Dart native
backend tests, 631 Python reference/CLI/MCP tests and 23 distribution/release
tests pass. The native suite covers Python-derived numeric fixtures, expression
safety, TCP and RTU-over-TCP simulator/gateway transactions, RTU-over-UDP,
framing/CRC recovery, timeout recovery, sniffer noise, WebDAV publication/history,
CSV/logging, custom template history and wide integer boundaries. Both native
Linux profile integration files pass independently under Xvfb: the local-demo
window covers polling, engineering writes, graphing and reconnect; the parity
window covers separate simulator/master tabs, rules, grouped reads, expressions,
logging, templates and workspace state. No Python bridge is started. The rebuilt
Linux release bundle is 25.70 MiB; the Windows release bundle is 29.67 MiB.
Both contain Flutter assets plus libserialport and have no `bridge` directory or
Python runtime. Both native Windows profile integration files also pass. The
Windows release executable opens a responsive `Modbus Connector Flutter` window,
with no backend children and no Qt/Python DLLs. The NSIS installer is 9,892,482
bytes (9.43 MiB), versus the previous local Flutter installer at 16,921,338 bytes,
a 41.54% reduction. This is an actual Windows build, not a cross-platform estimate.
The build used an isolated Windows staging directory and emitted MSB8029 temporary
build-directory warnings. Installation/upgrade/uninstall were not performed;
physical COM/RS-485, DPI and audio acceptance still require hardware.

## Historical verification records

The entries below are historical acceptance records; references to a parallel Qt
application or former release assets describe the state at the recorded date.

# Flutter desktop parity status

Release line: `0.16.0`. Updated 2026-10-28. The Flutter parity workspace feature
is integrated through `develop` into `main` for stable publication.
The PySide6 application, its settings, dependencies and
Windows installer remain available. Flutter now implements the main interactive
workflows below. It still has the explicit parity gaps listed later in this file.

## Delivered feature surface

| Area | Flutter implementation |
| --- | --- |
| Sessions | Independent Master/Simulator/Sniffer/Gateway tabs and owned bridge processes; inactive tabs keep working; tab/window shutdown waits for active I/O and releases services. |
| Master connections | TCP, serial RTU with discovery/manual port entry, RTU over TCP/UDP, timeout/unit/serial parameters, real loopback demo. Map reads/writes across all four areas; read-only areas cannot write. |
| Scanner | Persisted/recalled latest scan results/progress/selection; unit and address scans, editable probe list, range/area controls, progress, Stop, identification, alternate decoded formats, selected unit application and insertion of disjoint checked hits into the register map. |
| Register map | Primary virtualized table below the connection settings, toolbar jump, persisted column widths/order and header reset/movement; named rows across units/areas; counts, all Qt display formats/byte orders, scaling/units, engineering-value writes, enum/bit labels, 16-bit editor, checked rows, per-row polling intervals, adjacent/overlap grouped reads with individual fallback. |
| CSV / snapshots | CSV import preview and column mapping using the shared parser; selectable export columns including current formatted values; named raw snapshots and differences retaining added/removed row identities. |
| Expressions / advanced master | Safe AST expressions over latest scaled map values, individual errors, alarms/graph curves; device identification, diagnostics, FC 0x16 masks and FC 0x17 combined read/write. |
| Data logger | Selected register/expression rows, CSV wide snapshots or JSONL, metadata selection, interval, append/replace confirmation, incompatible-header rejection, flush/close. Fresh map dependencies for expressions can be acquired independently of map polling. |
| Alarms | Shared ordered conditions/ranges and red/yellow colors, entry/recovery logging, reentry and best-effort system alert sound. Scaled primary values drive evaluation. |
| Simulator | TCP, RTU over TCP and serial listeners; any/specific unit, editable map, datastore writes while stopped, external-master updates, tick interval, t/prev/[name]/rand/randint expression rules running in the bridge; prefix completion for references/functions with Up/Down, Enter/Tab and Escape. |
| Sniffer | Passive serial capture, per-unit recovered tables with saved column layouts, area/name/address filters, descending sort, hide/restore views and selected-unit graphs; editable names/formats/order, consecutive multiword decoding, sparklines, filtered traffic, graphs, CSV and overflow recovery. |
| Gateway | TCP, RTU over TCP or serial listener; TCP/RTU/RTU over TCP/UDP target; unit allowlist, traffic/status and clean stop. Reuses GatewayBackend. |
| Graphs | PNG export, nearest-timestamp hover/pinning, multiple selectable curves from reads/maps/logging/sniffer/expressions; min/max/mean/latest/hover values, shared or normalized scale, time window, pause, pan/zoom, clear, timestamped sample CSV. |
| Templates | Shared read-only public catalog; separate custom save/new-version/history/open-old-version/rename/delete with confirmation and final-version protection. Opens disconnected tabs. |
| Settings | Consolidated language, appearance, autosave toggle and workspace save/import/export dialog; separate atomic Flutter workspace autosave and manual export/import; tabs/active tab, drafts, maps/expressions, mode configuration, logger/scanner preferences, recovered sniffer state, theme and language. Invalid import preserves sessions; corrupt startup state disables automatic overwrite. |
| Help / language / appearance | English/Chinese Settings picker, localized Material controls and current-feature guide; centralized text widgets/dictionaries, generated Qt Chinese dictionary without importing Qt; system/light/dark theme. |
| Cloud | Separate WebDAV settings/password opt-in, consumer/publisher mode, test, current/history download, public publication and version activation, cancellable background tasks. Downloads update only Flutter's public cache. |
| Updates | Manual stable-release check, notes/current/latest, explicit errors and releases-page launch. UI/API explicitly report automatic Flutter installation as unsupported. |

The 900×650 Material 3 workspace retains independent scrolling panes. The named
map is embedded in the master page. Other tools are dialogs with wrapping controls
and scrollable content. File operations use native desktop choosers with manual
path entry when the plugin/host is unavailable. All addresses are zero-based PDU
addresses.

## Linux verification

Stable-release preflight (2026-10-28): Flutter analyzer clean; all 95 Flutter
unit/widget tests and 113 focused Python bridge/online/release/update/skill tests
passed. The UTF-8 subprocess regression now creates its own Chinese template
fixture instead of depending on a developer's template catalog. Native desktop
integration and physical-device tests were not rerun in this preflight; the
historical checks below retain their original scope.

Environment: Flutter 3.47.8 stable / Dart 3.13.7; Python 3.13.5 development and
Python 3.11.17 frozen bridge; x64 Linux, GTK 3, Xvfb.

| Check | Result |
| --- | --- |
| `flutter analyze --no-pub` | Clean after the Linux acceptance UI fixes (`PUB_CACHE=/tmp/parity-pub-cache`). |
| `flutter test --no-pub` | 57 tests passed after the Linux acceptance UI fixes. Includes live English/Chinese area/activity/probe/graph labels, localized row defaults and compact one-row versus scrolling 512-row maps. Existing controller/widget, minimum-size and text-scale coverage retained. |
| Historical broad Python regression | Earlier remaining-gap follow-up: 430 passed across bridge/online, backend/serial/models, simulator/gateway/sniffer, logger and Qt runtime tests. The prior broader 524-test run additionally covered custom templates, WebDAV and updates/install. |
| Historical PySide6 GUI regression | 33 passed in separate offscreen processes (`test_main_window_tabs.py`, `test_session_widget.py`) with settings isolated in temporary storage. Qt 6.10.3 runtime check also passed in the broad suite. |
| Latest bridge/online/backend/serial regression | 99 passed in the workspace follow-up (43 bridge/online tests), including display-only multiword rendering, per-row simulator rule failures and expression CSV/JSONL output. Includes real TCP/gateway, pseudo-terminal sniffer, WebDAV HTTP fixture, invalid requests, grouped slicing/fallback, files and shutdown. |
| Historical Ruff | Python adapters and tests clean; no Python code changed in this workspace follow-up. |
| Native desktop integration | Workspace follow-up: both `desktop_test.dart` and `parity_test.dart` passed independently under Xvfb, using real bridge processes. |
| `flutter build linux --release --no-pub` | Workspace follow-up: passed with the native file-selector plugin; executable under `flutter_app/build/linux/x64/release/bundle/`. |
| Baseline native bridge freeze | PyInstaller build passed, including public template data and excluding Qt/numpy. |
| Baseline frozen bridge from `/tmp` | Independent simulator/master, grouped reads, expressions, logger, bundled/custom templates, cloud settings and EOF cleanup passed without `MODBUS_PYTHON`. |
| Baseline packaged release from `/tmp` | Found adjacent frozen bridge without Python override; demo connected/read; master, named map/scaled/bitmask values and scanner visually inspected at 900×650. |

`desktop_test.dart` covers four areas, writes, 10 Hz polling, chart, protocol
errors, refused connections, disconnect/reconnect, bridge exit/restart and cleanup.
`parity_test.dart` covers separate simulator/master tabs, simulator expressions,
grouped map reads, scaled master expressions, snapshots, CSV logger/templates,
workspace save and closing one tab while the other remains running. The workspace
follow-up verifies expression logger columns and map polling while scrolling away
from the embedded table.

Run the native integration files separately. A combined invocation failed when
launching its second native app (debug connection/log reader); both standalone
commands passed. Xvfb desktop checks emitted GTK accessibility/window-teardown
warnings; there were no Flutter layout failures in the verified scenarios.
Baseline frozen-bridge/package checks above predate these follow-up commands;
the current release UI build was verified with the source Python bridge in native
integration tests. Desktop sound audibility was not verified. WebDAV uses a local fixture, not an
external account. No physical Modbus/serial device was available.

## Remaining parity and validation gaps

- Column hiding/restore, compact rows, raw quick actions, copying and row trends
  are implemented and persisted. Exhaustive keyboard/accessibility coverage and
  further Qt view-management conveniences remain unverified.
- Sniffer filters, hidden views, per-unit columns/graphs and serial discovery in
  Simulator/Sniffer/Gateway forms are complete. More extensive Qt view management
  and a byte-for-byte Qt layout are deferred.
- Simulator prefix autocomplete is complete; public/custom templates still append
  with duplicate area/address checks. Qt's manufacturer submenu layout is deferred.
- Graphs support owned detached native viewers with sample pipes, saved selection,
  time window and normalization, and reset zoom. Parent sessions retain all bus
  ownership; closing a session closes its graph viewers.
- Dynamic message templates and touched prompts/tool captions now translate in
  English/Chinese, including common validation/file failures and rule errors.
  Unrecognized third-party/system diagnostics and some untouched captions can
  still appear in English. Canonical register-map CSV stays Qt-compatible and
  therefore omits some Qt row/display metadata; expression logger columns are
  supported without extending that schema (JSONL kind `expression` is documented).
- Flutter has an independent Windows NSIS installer and verified installed x64
  runtime. Automatic update handoff, signing and public release workflow remain
  deferred; currently published NSIS assets target Qt. Physical RTU/USB timing,
  multi-monitor DPI/audio, multi-client load and the broader platform/performance
  matrix still require hardware and environment validation.

## Local implementation commits

The parity push is split into 13 implementation commits, in delivery order:
sessions; scanner; register/CSV/snapshot tools; logger/alarms; device modes;
graphs; templates/state; help/language; cloud/updates; expressions/advanced
functions/cancellation; grouped scheduling; CSV/alarm/theme refinements; full-map
protocol capacity/sniffer snapshots. The final documentation commit consolidates
this inventory. Earlier per-chunk validation notes remain in Git history.

Setup, running, native packaging and exact standalone integration commands:
[flutter_app/README.md](../flutter_app/README.md). Historical verification notes
below refer to earlier follow-ups on the migration branch.

## Remaining-gap follow-up chunks

- Session-owned register-map polling: analyzer clean; 12 targeted map/session
  tests pass, including dialog close and disconnect cancellation. No new bridge
  commands or Qt changes.

- Native file selectors (CSV/workspace/snapshots/logger/graph), snapshot JSON
  exchange, PNG export and timestamp-based graph inspection: native cancellation
  and missing-plugin fallback covered by widget tests; analyzer clean. Scanner
  results/progress/selection saved alongside preferences and restored disconnected.

- Device editing follow-up: simulator template-to-map conversion, shared raw
  enum/bit editors, expression insertion chips and per-row rule failures; sniffer
  format/order/multiword views, numeric sparklines and selected-unit traffic.
  Added display-only `render_rows` and documented simulator rule error payloads.
  Python bridge/online: 41 passed; Flutter analyzer clean and device/template/
  sniffer tests pass. Qt backends/UI and canonical CSV schema remain unchanged.

- Map editing/logger/localization follow-up: separate row selection, batch/context
  menus, raw inline enum writes, Ctrl+A/Ctrl+R/Ctrl+Shift+R/Ctrl+Up/Down/Delete/
  Ctrl+N, selected expression logging with fresh dependencies, unchanged canonical
  CSV schema, parameterized Chinese technical errors/prompts. Focused tests cover
  raw enum writes versus scaling, shortcut actions, expression-only acquisition,
  safe CSV/JSONL expression output and dynamic Chinese messages.

Final follow-up checks: analyzer clean; 38 Flutter tests, 43 bridge/online tests
(included in 430 Python regressions), 33 isolated Qt GUI tests; both native
integration files passed separately under Xvfb. Linux release build includes
the file-selector plugin. PNG bytes, chooser cancellation/fallback, inline raw
enums, sniffer edits during traffic and late-expression cancellation are covered.

## Workspace UI follow-up: closed versus deferred

Closed in `feature/flutter-parity-workspace`:

- Master map is embedded and its toolbar scrolls to it; polling remains owned by
  the session. Map and sniffer tables virtualize rows and persist resized/reordered
  columns, with header movement/reset actions and recovery from invalid layouts.
- English/Chinese captions, prompts, dynamic titles and Material localization are
  wired through the shared language setting. The minimum 900×650 master window
  also fits Chinese text at 1.5× scaling.
- Simulator, Sniffer, Gateway listen and Gateway target serial forms discover ports,
  support selection, empty-list cancellation and manual entry, and preserve other
  serial parameters. Running services lock the connection forms.
- Sniffer supports area/name/address filters, descending addresses, hide/restore
  without losing raw words or multiword decoding, saved per-unit column layouts
  and graphs (including their time window and Clear action) restricted to the
  selected unit. Snapshot responses remain attached to the requested unit if the
  user switches units during the request.
- Simulator rules complete reference/function prefixes, preserve expression
  suffixes and support keyboard selection/insertion/dismissal.
- Settings groups language, theme, autosave and explicit workspace save/import/
  export. Autosave preference and layouts round-trip independently of Qt settings.

The later Windows follow-up below closes detached graphs, additional table
conveniences and installer/runtime validation. Further view conveniences,
unrecognized external diagnostics and hardware validation remain open. No Qt settings,
backend behavior or canonical CSV schema changed in this follow-up.

Validation for this follow-up uses the cached SDK dependencies with
`PUB_CACHE=/tmp/parity-pub-cache` and `--no-pub`. The Linux checks are recorded in
the verification table above; earlier packaging/freeze results remain historical.

Linux acceptance UI fixes (2026-10-24): quick-table area titles, connection/polling
activity, default register names, the Chinese `dec` gloss, scanner probe/result
labels and graph legends/statistics follow the language setting. Specific dynamic
translations take precedence over broad message patterns. The embedded map sizes
to short content and caps its scrolling body for larger maps, removing the fixed
470-pixel card height. Protocol area/format tokens and Qt code are unchanged.
Native acceptance verification of these fixes remains with Grok Bot.

## Windows feature completion and installed acceptance (2026-10-24)

Added column hide/restore and compact density, raw map quick writes and shortcuts,
map row trends, graph settings persistence/reset and separate native viewers,
template search, activity log filters/copy/export, master raw TX/RX capture and
statistics, and explicit Qt configuration migration. Template conversion now
handles blank inherited unit/interval/order fields. Bundled manufacturer JSON
maps were removed from the app package; public templates load from the cloud
cache. UTF-8 cloud cache loading is explicit on Windows.

Viewers receive bounded samples through owned subprocess pipes and never open a
second Modbus connection. Session shutdown closes their pipes and waits for exit.
Graph content scrolls at small window sizes; the detached surface follows theme.
Tables keep lazy rows and persisted column layouts rather than adding more fixed
toolbar rows. Canonical CSV and the Qt GUI remain unchanged.

| Windows check | Result |
| --- | --- |
| Toolchain | Windows x64; Flutter 3.47.8 / Dart 3.13.7; Python 3.12; VS 2022 C++ toolset; NSIS 3.11. |
| Static / Flutter tests | Analyzer clean; 61 widget/controller tests passed; targeted Python Ruff clean. |
| Python regression | 509 passed, 3 skipped across bridge/online, backend/models, simulator/gateway/sniffer, logger, templates, cloud and updates; subsequent bridge/online additions: 45 passed, 1 skipped. |
| Native integration | Both desktop and parity test files passed separately on Windows using real subprocess bridges and local TCP simulation. |
| Release packaging | Windows Release and Qt/numpy-free frozen bridge built; independent `ModbusConnectorFlutter` NSIS package produced. |
| Frozen installed backend | Tested from an unrelated working directory without Python override: separate simulator/master, read/write, traffic, expression, CSV logger, public/custom templates, and EOF listener/process cleanup passed. |
| Installed UI | Chinese layout inspected at 1280×800; real local demo connected, polled, wrote/reread a holding register; raw traffic/statistics displayed; detached graph received ongoing samples while main controls remained available; closing the main window during polling exited all three owned processes (main, bridge and graph). |
| Preservation | Hashes of the four pre-existing Qt settings/cloud/cache/custom-template files unchanged after installation. Flutter owns separate install registration, shortcuts and data. |

Installer: `dist/modbus-connector-flutter-0.16.0+6-windows-x64-setup.exe`.
Installed location: `%LOCALAPPDATA%\Programs\ModbusConnectorFlutter`.
All 103 installed payload files match the final Release SHA-256 hashes.
Run `flutter_app/tool/verify_windows_bundle.py --bundle <installed directory>`
to repeat isolated frozen-backend acceptance. Local evidence logs are under the
ignored `tools/` directory. The portable Release directory remains usable.

This acceptance uses local TCP simulation and test WebDAV fixtures. No physical
RTU/USB device, external WebDAV account, multi-monitor DPI or audible alarm was
validated. Automatic Flutter updates remain manual until separately identified
Flutter assets and an upgrade handoff are implemented and published.

Template-open repair: Qt templates omit default kind/format/scale/offset fields;
the adapter now emits explicit defaults required by Flutter restoration. Master
maps retain up to 4096 rows instead of silently truncating to 512, including the
1832-row EMS template. Open errors and the 64-tab limit remain visible in the
dialog. A native Windows regression restores every public template and clicks
Open latest for public, custom and the largest catalog template, checking row
counts, selected disconnected tabs, retained connection parameters and dialog closure.
Form listeners attach only after every restored value is loaded, avoiding an early
change listener overwriting the rest of a template's connection defaults. Large-map protocol/CSV
round trips cover 1832/4096 rows; logging and simulator limits remain separate.
Installed-only root cause: frozen Windows Python ignored `PYTHONIOENCODING` and
decoded raw UTF-8 Chinese resource paths using its system code page, reporting
template-not-found with garbled filenames. Bridge main now explicitly configures
stdin/stdout/stderr as UTF-8. Frozen acceptance sends unescaped Unicode like Dart
instead of ASCII JSON escapes; all public templates must load and plan all rows.
Subprocess regressions force GBK and cp1252 to verify the protocol remains UTF-8.
Windows repair acceptance: bridge/online tests passed (50 passed, 1 skipped),
Flutter tests passed (61), analyzer clean, and native template integration passed.
The rebuilt installed bundle passed all 26 public templates with raw Unicode
requests. Manual installed-UI verification selected the Chinese Xinghuan outdoor
unit template, clicked Open latest, and confirmed a new selected disconnected
tab with populated Chinese register names and addresses. All 103 installed
payload files matched the rebuilt Release bundle.

## Unified master workspace (2026-10-25)

Removed the quick contiguous read/write controls, raw range table and single-row
chart. Connection settings now lead directly into the register map; manual rows,
templates, map reads/polling, writes and multi-series graphs share that workspace.
Activity stays below the map. Address scanner results add selected addresses to
the map, without a second range-opening action. Legacy query fields are ignored on restore and omitted from new saves; opening
an old workspace never starts I/O.
Validation: analyzer clean, all 62 Flutter tests passed, and the Windows native
integration passed with manual row addition, real map read/write/reread, map
poll/stop and reconnect through the local simulator. Rebuilt and installed the
Windows Release; all 103 payload hashes matched. Existing workspace was bytewise
unchanged by installation; its three tabs and 248-row map restored in the UI.
Installed Chinese UI confirms connection settings lead directly into the map.

## Quick-range residue cleanup and demo repair (2026-10-25)

Removed the unused LiveChart/WriteDialog widgets, ReadQuery, quick read/write
methods, quick polling timer/cancellation state and 300-sample selection buffer.
Map polling retains its own cancellation generations and bounded graph histories.
Old workspace query/interval fields are ignored; obsolete draft fields are dropped.
Shared Python read/write commands remain necessary for tools and protocol clients.

A real regression reproduced input-register map reads returning zero in demo mode:
only the former raw read path advanced the simulator. Map reads now advance the
same real simulator before I/O, including grouped reads, while preserving writes.
Workspace → Local demo opens an isolated tab with six named example rows covering
all four areas, scaled signals/setpoint, a counter and switch/contact names. It
connects and polls at 500 ms; choosing demo in a device form opens the same isolated
workflow. Restored sessions never auto-connect. Reconnect resets simulator data.
README/help now describe the map workflow instead of the deleted quick controls.

Validation: Python bridge/online tests passed (51 passed, 1 skipped); Ruff and
Flutter analyzer were clean; all 66 Flutter tests passed. Both Windows native
integration files passed separately against real loopback simulator processes.
The demo test covers animated grouped reads, engineering writes, switch changes,
graph histories, stop/disconnect and reconnect reset. The frozen bundle verified
all 26 public templates, four demo areas, writes and reset without external Python.
Installed Release payload hashes matched all 103 files; installation preserved
the workspace byte for byte. Installed Chinese UI restored the existing two tabs
and 248-row device map. Opening a demo added an isolated tab; live trends and a
keyboard-entered 23.5 °C write/readback were verified. Hardware serial I/O was not
part of this demo validation.

## Windows UI responsiveness (2026-10-25)

Independent map reads used to publish busy changes for every bridge request,
rebuilding the workbench, connection form, tab chip and visible table repeatedly.
Map acquisition now publishes at cycle boundaries, retaining serialized I/O,
per-group cancellation and immediate disconnect/bridge-exit handling. Progress
keeps a fixed height so the table does not jump under the pointer. Inactive tabs
mute animation tickers while their connections and acquisition remain active.

A native Windows Profile benchmark uses the real Python bridge, 248 independent
rows and a controlled 2 ms response delay. Over three read cycles UI notifications
fell from 1500 to 12. Mean frame build time fell from 7.092 to 1.299 ms; the 90th
percentile fell from 11.472 to 3.293 ms. Build-budget misses fell from 3 to 0.
With 1000 samples per history, continuous table flings measured 1.594 ms at the
90th percentile, and repeated client-area resizing measured 12.626 ms, both under
the 16.7 ms budget with no build-budget misses. These are local machine results,
not physical-device or multi-monitor performance guarantees. Run the reproducible
Profile command in `flutter_app/README.md`; the benchmark emits JSON frame data.

Validation: Flutter analyze clean; the full 68-test suite passed, followed by the
11-test map suite including the added progress-position regression. Native demo
and TCP simulator/parity files passed separately. Regressions cover bounded UI
notifications, hidden-tab animation quiescence, active-read cancellation and
table position stability. No Python backend or register protocol behavior changed.
The frozen bridge bundle verifier passed. The Release installer updated the local
Flutter application; all 103 payload files matched the build and the workspace
was unchanged by installation. Installed UI checks covered the existing 248-row
map's scrolling, native window dragging, demo polling and switching back to the
device tab while the demo was running. All three maps and connection settings
matched their pre-install backup after those checks.

## Selection column and mouse sweep (2026-10-25)

Removed the separate polling checkbox column. Row/batch context actions retain
enable/disable polling; disabled rows show a pause marker and muted name without
losing their saved polling flags. Selection is temporary and independent of I/O.
Old column IDs are ignored by the existing layout validator.

Like Qt's checkbox sweep, dragging the left mouse button along the selection
column inverts every crossed row once per gesture, including skipped rows and
reverse movement. Edge auto-scroll supports long virtualized maps. The viewport
owns the recognizer, so recycling the starting row does not cancel selection.
The recognizer accepts mouse gestures only inside the current selection column,
including reordered/resized columns; normal scrolling and row editing remain.
Checkbox accessibility actions are retained. Native integration retires its
synthetic mouse before subsequent touch-driven interactions to avoid stale hover
state in the Windows accessibility bridge.

Validation: Flutter analyze clean; all 72 unit/widget tests passed. Windows
Profile integration passed real-bridge reads, mouse sweep, batch polling flags,
pause markers and rereading, then full-history scrolling and window resizing.
Widget regressions cover mixed initial states, skipped/reversed rows, ordinary
clicks, other-column drags, edge auto-scroll across recycled rows and cleanup.
The Release installer updated the local application; all 103 payload files
matched the build. Installed UI checks verified four-row mouse sweep selection,
repeat sweep deselection and the polling context menu on the existing 248-row
map. All three tabs and the saved workspace remained unchanged after these checks.

Batch polling now has explicit Enable polling / Disable polling toolbar buttons.
They affect selected rows only and are disabled without a selection or during
active I/O. Their presence is stable while sweeping, avoiding table movement.
The map utility dialog scrolls its contents on small windows or larger text.
Validation: analyzer clean, all 73 unit/widget tests passed, and Windows Profile
integration passed selection, both buttons, real-bridge reads, scrolling and
resizing. The new regression checks skipped reads, resuming reads, unselected-row
isolation and saved polling flags. The installed Release UI also verified drag
selection, cancellation pause markers and reenabling on three rows.

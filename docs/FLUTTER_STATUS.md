# Flutter desktop parity status

Branch: `feature/flutter-ui-migration`. Updated 2026-10-24. Work is committed
locally; no push or PR. The PySide6 application, its settings, dependencies and
Windows installer remain available. Flutter now implements the main interactive
workflows below. It still has the explicit parity gaps listed later in this file.

## Delivered feature surface

| Area | Flutter implementation |
| --- | --- |
| Sessions | Independent Master/Simulator/Sniffer/Gateway tabs and owned bridge processes; inactive tabs keep working; tab/window shutdown waits for active I/O and releases services. |
| Master connections | TCP, serial RTU with discovery/manual port entry, RTU over TCP/UDP, timeout/unit/serial parameters, real loopback demo. Quick reads/writes in all four areas; read-only areas cannot write. |
| Scanner | Unit and address scans, editable probe list, range/area controls, progress, Stop, identification, alternate decoded formats, selected unit/range application and insertion of disjoint checked hits into the register map. |
| Register map | Named rows across units/areas; counts, all Qt display formats/byte orders, scaling/units, engineering-value writes, enum/bit labels, 16-bit editor, checked rows, per-row polling intervals, adjacent/overlap grouped reads with individual fallback. |
| CSV / snapshots | CSV import preview and column mapping using the shared parser; selectable export columns including current formatted values; named raw snapshots and differences retaining added/removed row identities. |
| Expressions / advanced master | Safe AST expressions over latest scaled map values, individual errors, alarms/graph curves; device identification, diagnostics, FC 0x16 masks and FC 0x17 combined read/write. |
| Data logger | Selected register rows, CSV wide snapshots or JSONL, metadata selection, interval, append/replace confirmation, incompatible-header rejection, flush/close. Samples can be acquired independently of map polling. |
| Alarms | Shared ordered conditions/ranges and red/yellow colors, entry/recovery logging, reentry and best-effort system alert sound. Scaled primary values drive evaluation. |
| Simulator | TCP, RTU over TCP and serial listeners; any/specific unit, editable map, datastore writes while stopped, external-master updates, tick interval, t/prev/[name]/rand/randint expression rules running in the bridge. |
| Sniffer | Passive serial capture, per-unit recovered maps, editable register names, traffic, graph values, CSV with values and explicit map recovery after event overflow. |
| Gateway | TCP, RTU over TCP or serial listener; TCP/RTU/RTU over TCP/UDP target; unit allowlist, traffic/status and clean stop. Reuses GatewayBackend. |
| Graphs | Multiple selectable curves from reads/maps/logging/sniffer/expressions; min/max/mean/latest/hover values, shared or normalized scale, time window, pause, pan/zoom, clear, timestamped sample CSV. |
| Templates | Shared read-only public catalog; separate custom save/new-version/history/open-old-version/rename/delete with confirmation and final-version protection. Opens disconnected tabs. |
| Settings | Separate atomic Flutter workspace autosave and manual export/import; tabs/active tab, drafts, maps/expressions, mode configuration, logger/scanner preferences, recovered sniffer state, theme and language. Invalid import preserves sessions; corrupt startup state disables automatic overwrite. |
| Help / language / appearance | English/Chinese picker and current-feature guide; centralized text widgets/dictionaries, generated Qt Chinese dictionary without importing Qt; system/light/dark theme. |
| Cloud | Separate WebDAV settings/password opt-in, consumer/publisher mode, test, current/history download, public publication and version activation, cancellable background tasks. Downloads update only Flutter's public cache. |
| Updates | Manual stable-release check, notes/current/latest, explicit errors and releases-page launch. UI/API explicitly report automatic Flutter installation as unsupported. |

The 900×650 Material 3 workspace retains independent scrolling panes. Most tools
are dialogs with wrapping controls and scrollable content. File operations
currently use editable paths. All addresses are zero-based PDU addresses.

## Architecture and storage

Flutter uses the existing Qt-free synchronous Python backends through an owned
NDJSON subprocess per session. New adapters reuse models/CSV/expression/alarm
logic, DataLogger, SimBackend, SnifferBackend, GatewayBackend, custom templates,
WebDAV and the stable release checker. No Qt or numpy is needed by the bridge.
The request limit is bounded at 2,097,152 characters, sufficient for full 512-row
maps; oversize-frame recovery remains supported. Protocol additions are in
[BRIDGE_PROTOCOL.md](../flutter_app/BRIDGE_PROTOCOL.md).

Each session serializes transactions, skips busy timer ticks and cancels between
read groups. Stop suppresses late read/error/alarm/graph effects. Disconnect and
shutdown wait for active I/O; EOF closes connections, servers, logger files and
simulator rule timers. Template/cloud/update dialogs own a separate utility
bridge, preserving ongoing bus sessions.

Flutter data uses `~/.modbus_connector/flutter` (Windows:
`%USERPROFILE%\.modbus_connector\flutter`), overridable with `MODBUS_FLUTTER_HOME`:

- `settings.json`: schema-1 workspace; sessions always restore disconnected.
- `custom_templates/`: personal version histories, separate from Qt histories.
- `cloud_templates.json`: validated, atomically replaced public catalog overlay.
- `cloud.json`: separate settings; password saved only with explicit opt-in.

Workspace exports and public cloud publication exclude cloud credentials. Cloud
transfers never replace sessions or personal templates. Consumer mode rejects
backend writes before network access; server permissions still apply.

## Linux verification

Environment: Flutter 3.47.8 stable / Dart 3.13.7; Python 3.13.5 development and
Python 3.11.17 frozen bridge; x64 Linux, GTK 3, Xvfb.

| Check | Result |
| --- | --- |
| `flutter analyze` | Clean. |
| `flutter test` | 26 tests passed. Controllers/widgets cover independent tabs, cancellation, scanner, maps/scheduling/snapshots/bits, logging/alarms, modes, graphs, persistence, Chinese/help and cloud task cancellation. Existing minimum-size/large-table/text-scale tests retained. |
| Broad Python regression | 524 passed across bridge/online, backend/serial/models, simulator/gateway/sniffer, logger, custom templates, WebDAV, updates/install and Qt runtime tests. |
| Existing PySide6 GUI regression | 33 passed in separate offscreen processes (`test_main_window_tabs.py`, `test_session_widget.py`) with settings isolated in temporary storage. Qt 6.10.3 runtime check also passed in the broad suite. |
| Latest bridge/online regression | 39 passed after final CSV, frame-capacity and custom-sniffer-state refinements. Includes real TCP/gateway, pseudo-terminal sniffer, WebDAV HTTP fixture, invalid requests, grouped slicing/fallback, files and shutdown. |
| Ruff | New/changed Python adapters and tests clean. |
| Native desktop integration | Both `desktop_test.dart` and `parity_test.dart` passed independently under Xvfb, using real bridge processes. |
| `flutter build linux --release` | Passed; executable under `flutter_app/build/linux/x64/release/bundle/`. |
| Native bridge freeze | PyInstaller build passed, including public template data and excluding Qt/numpy. |
| Frozen bridge from `/tmp` | Independent simulator/master, grouped reads, expressions, logger, bundled/custom templates, cloud settings and EOF cleanup passed without `MODBUS_PYTHON`. |
| Packaged release from `/tmp` | Found adjacent frozen bridge without Python override; demo connected/read; master, named map/scaled/bitmask values and scanner visually inspected at 900×650. |

`desktop_test.dart` covers four areas, writes, 10 Hz polling, chart, protocol
errors, refused connections, disconnect/reconnect, bridge exit/restart and cleanup.
`parity_test.dart` covers separate simulator/master tabs, simulator expressions,
grouped map reads, scaled master expressions, snapshots, CSV logger/templates,
workspace save and closing one tab while the other remains running.

Run the native integration files separately. A combined invocation failed when
launching its second native app (debug connection/log reader); both standalone
commands passed. Xvfb desktop checks emitted GTK accessibility/window-teardown
warnings; there were no Flutter layout failures in the verified scenarios.
Desktop sound audibility was not verified. WebDAV uses a local fixture, not an
external account. No physical Modbus/serial device was available.

## Remaining parity and validation gaps

- Named-map polling currently runs while its dialog is open and stops on close.
  The quick range, background logger and device services continue independently;
  Qt's permanently visible full register table is not reproduced yet.
- Native file choosers, table column sizing/reordering, batch/context-menu actions,
  extensive shortcuts, inline enum editors and some editing/validation polish
  remain below the Qt UI. Scanner preferences persist; scanner result history is
  not a full Qt-equivalent saved scanner window.
- Sniffer lacks Qt's complete per-row format editing, multiword views, sparklines
  and per-unit filtered log experience. Names/values, raw graph data, traffic and
  CSV are usable. Device-mode forms accept manually typed serial ports.
- Simulator lacks the complete Qt template-menu workflow, enum/bit convenience
  editors, expression autocomplete and per-row rule-error presentation. Rules,
  map edits and external master traffic work. Public templates primarily open
  master maps; loading them is not an automatic simulator-map conversion.
- Expression rows use latest register-map values; expression selection/output is
  not integrated into the logger. Some Qt row/display options are not exported
  by the shared canonical CSV schema.
- Graphs remain in-window dialogs; detached native graph windows and image export
  are not implemented. Hover/sample selection is approximate in time.
- Some dynamic technical errors, freeform prompts and tool captions still fall
  back to English; English/Chinese localization is substantial, not complete.
- Automatic Flutter install/update, a Flutter-specific installer/product identity,
  code signing and release workflow remain. Existing NSIS assets install the Qt
  product and are deliberately not launched by Flutter on Linux or Windows.
- Windows compilation/runtime, copied release bundle without Python, DPI/audio,
  COM hardware and shutdown remain user-verified later. Existing Windows runner
  and setup/package instructions are retained; no Windows binary is claimed.
- Physical RTU, USB timing, multi-client load and a broad Linux distribution/perf
  matrix require validation beyond loopback/pseudo-terminal tests on this box.

## Local implementation commits

The parity push is split into 13 implementation commits, in delivery order:
sessions; scanner; register/CSV/snapshot tools; logger/alarms; device modes;
graphs; templates/state; help/language; cloud/updates; expressions/advanced
functions/cancellation; grouped scheduling; CSV/alarm/theme refinements; full-map
protocol capacity/sniffer snapshots. The final documentation commit consolidates
this inventory. Earlier per-chunk validation notes remain in Git history.

Setup, running, native packaging and exact standalone integration commands:
[flutter_app/README.md](../flutter_app/README.md). The pre-existing untracked
`docs/FLUTTER_MIGRATION_BRIEF.md` was left untouched.

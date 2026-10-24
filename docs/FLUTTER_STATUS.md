# Flutter desktop parity status

Branch: `feature/flutter-parity-workspace`. Updated 2026-10-24. Work is committed
locally; no push or PR. The PySide6 application, its settings, dependencies and
Windows installer remain available. Flutter now implements the main interactive
workflows below. It still has the explicit parity gaps listed later in this file.

## Delivered feature surface

| Area | Flutter implementation |
| --- | --- |
| Sessions | Independent Master/Simulator/Sniffer/Gateway tabs and owned bridge processes; inactive tabs keep working; tab/window shutdown waits for active I/O and releases services. |
| Master connections | TCP, serial RTU with discovery/manual port entry, RTU over TCP/UDP, timeout/unit/serial parameters, real loopback demo. Quick reads/writes in all four areas; read-only areas cannot write. |
| Scanner | Persisted/recalled latest scan results/progress/selection; unit and address scans, editable probe list, range/area controls, progress, Stop, identification, alternate decoded formats, selected unit/range application and insertion of disjoint checked hits into the register map. |
| Register map | Embedded, virtualized table below the quick view, toolbar jump, persisted column widths/order and header reset/movement; named rows across units/areas; counts, all Qt display formats/byte orders, scaling/units, engineering-value writes, enum/bit labels, 16-bit editor, checked rows, per-row polling intervals, adjacent/overlap grouped reads with individual fallback. |
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

- Additional Qt table/display options (including column hiding) and exhaustive
  keyboard/accessibility coverage remain deferred. The embedded named map,
  column resize/reorder/reset and their persistence are complete in this scope.
- Sniffer filters, hidden views, per-unit columns/graphs and serial discovery in
  Simulator/Sniffer/Gateway forms are complete. More extensive Qt view management
  and a byte-for-byte Qt layout are deferred.
- Simulator prefix autocomplete is complete; public/custom templates still append
  with duplicate area/address checks. Qt's manufacturer submenu layout is deferred.
- Graphs export PNG and use timestamp-based, zoom-aware hover/pinned inspection;
  detached native graph windows remain deferred. A separate native window/plugin
  lifecycle was not introduced in this run.
- Dynamic message templates and touched prompts/tool captions now translate in
  English/Chinese, including common validation/file failures and rule errors.
  Unrecognized third-party/system diagnostics and some untouched captions can
  still appear in English. Canonical register-map CSV stays Qt-compatible and
  therefore omits some Qt row/display metadata; expression logger columns are
  supported without extending that schema (JSONL kind `expression` is documented).
- Flutter automatic install/update, installer identity, code signing and release
  workflow remain outside this run. Existing NSIS assets install Qt. Windows
  compilation/runtime/COM/DPI/audio, physical RTU/USB timing, multi-client load and
  the broader distro/performance matrix remain user/hardware verification work.

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

Deferred items remain in the gap list above: detached native graph windows,
additional Qt display/view conveniences, unrecognized external diagnostics,
Flutter installer/release identity and Windows/hardware validation. No Qt settings,
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

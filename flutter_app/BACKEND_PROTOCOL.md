# Desktop backend contract v1

`NativeBridge` owns one `NativeService` per session and passes Dart maps to an owned isolate;
there is no desktop pipe protocol or Python child. The internal names
`BridgeTransport`/`BridgeReply` remain to preserve the UI's adapter boundary and
fake transports in widget tests. Each request has a `command`; each service reply
has `ok`, `connected`, and either `result` or `error` (`type`, `message`, optional
Modbus `exception_code`). Calls validate ranges before bus I/O.

Responses also contain `traffic` (up to 256 captured master TX/RX chunks from the
request) and cumulative `statistics`. Each frame has `direction`, ISO `time`,
original byte `length` and uppercase space-separated `hex` (at most 4096 bytes).
Statistics include `tx_bytes`, `rx_bytes`, `operations`, `errors`, `average_ms`.
An operation is a service request that exchanged master traffic, including failed
requests; grouped reads count as one operation. Flutter retains the latest 500
chunks. Display pause/filtering never pauses capture or bus I/O.

```json
{"id":1,"command":"hello"}
{"id":1,"ok":true,"connected":false,"result":{"protocol":1}}
{"id":2,"command":"connect","transport":"tcp","host":"127.0.0.1","port":502,"timeout":3}
{"id":3,"command":"read","unit":1,"kind":"holding_registers","address":0,"count":50}
{"id":4,"command":"write","unit":1,"kind":"holding_registers","address":0,"values":[42]}
{"id":5,"command":"disconnect"}
{"id":6,"command":"shutdown"}
```

Commands:

- `hello`: protocol version; no I/O.
- `ports`: `result.ports` is an array of `{port, description}` serial devices.
- `connect`: TCP as above; RTU uses `transport: "rtu"`, `port: "COM3"` (or a
  device path), `baudrate: 9600`, `bytesize: 8`, `parity: "N"`, `stopbits: 1`,
  `timeout: 3`. Timeout accepts 0.1–60 seconds. `transport: "demo"` starts the
  native Dart simulator on an ephemeral loopback TCP port and connects the real
  `ModbusClient`. Successful connects return `result.description`. Demo holding
  addresses 0–124 start at 100; input registers 0–124 animate; bits 0–1999 have
  seeded patterns. Other simulator addresses up to 9999 start at zero.
- `read`: unit 1–247, four canonical `RegisterKind` strings, **0-based PDU**
  address 0–65535, count 1–125 registers / 1–2000 bits; range cannot overflow.
  Returns `result.values` (integers/booleans) and `elapsed_ms`.
- `write`: coils or holding registers only. Non-empty `values`, bool/0/1 coils,
  unsigned 0–65535 registers, at most 1968 coils / 123 registers. Returns
  `elapsed_ms`. The quick-range tool writes one row and rereads the selected range; the
  register-map tool also supports multi-register writes.
- `disconnect`: closes the backend and demo, keeps service alive for reconnect.
- `shutdown`: closes resources, acknowledges, exits. EOF also closes resources.

Dart asynchronous sockets and serialized per-session transactions keep the UI
responsive. Stop invalidates the current read generation; Disconnect gates the
UI immediately and waits for active I/O. Recoverable transaction errors keep
polling alive. TCP transaction IDs reject late replies; RTU drains one timeout
before the next request after a timeout. EOF/shutdown language below describes
the retained Python reference adapter only; desktop close awaits each owned Dart
service, cancels rules/cloud work and closes log files, listeners and ports.

Every tab owns independent services and bus resources. Separate graph viewer
processes are Flutter executables fed with graph data, not backend processes.

Scanner commands (v1 additive):

- `scan_unit`: `unit` 1..247, `probes` array (1..32) of `{kind,address,count}`.
  Returns `{unit,hits}` where hits are responding probe indices. Invalid probe
  ranges fail before I/O. Flutter submits one probe per request so Stop takes
  effect after the current backend transaction, suppressing late results.
- `scan_address`: `unit`, `kind`, `address`; returns `{address,values}`. Reuses
  backend pair reads and count=1 fallback for register areas; bits read one.
  Empty values means no response. Transport loss is an error.
- `device_id`: `unit`; returns `{objects}` from FC 0x2B/0x0E (string JSON keys).

Scanner owns that tab's bus while running. Polling stops before a scan. Progress
and hits remain visible after Stop; applying a result updates the session's unit
or selected contiguous address range. Other tabs remain usable.

Register map commands (additive v1):

- `read_rows`: `{unit, rows:[row,...]}` (1..4096). Each row accepts `name`, `kind`,
  `address`, `count`, `unit_id` (null inherits unit), `format`, `order`, `scale`,
  `offset`, `unit`, `value_names` (string integer keys), `bitmask`, `alarms`.
  Formats: dec/hex/s16/u32/s32/f32/u64/s64/f64/ascii/ascii1; byte orders
  ABCD/CDAB/BADC/DCBA. All rows validate before I/O, including format width.
  Returns `{rows:[{values,display,numeric,alarm}],elapsed_ms}`. Nonfinite numeric
  values become null. Flutter reads one row per request for cancellation.
- `encode_values`: `{row,text}` converts engineering values to raw values using
  the same byte order and inverse scaling. Returns `{values}`; zero scale,
  wrong count, nonfinite values and invalid rows fail. Does not write hardware.
- `csv_parse`: `{text,preview:true}` returns `{header,mapping}`. With optional
  `mapping` (source column → canonical field), returns `{rows}`. Uses the shared
  CSV parser. Essential fields: name/kind/address.
- `csv_export`: `{rows,columns?,include_values?}` returns `{text}` using canonical
  CSV fields. Optional `value` column renders raw `rows[].values` (or a sniffer
  scalar `value`) with the row format/scaling; missing samples export empty cells.
  Columns can be selected; no filesystem access in these commands.

Flutter reads/writes CSV files, retains raw named snapshots in the session, and
compares snapshots without issuing writes. The register map has independent named
rows and polling; the quick contiguous range remains available in the master view.

Logger commands:

- `logger_start`: `{path,format:"csv"|"jsonl",interval_ms,append,fields,rows}`.
  Path is local to the owned service; append defaults true. Validates rows/settings
  before opening. CSV columns are timestamp + fixed `name@unit_id_address` labels with engineering
  units in parentheses; CSV values omit the unit suffix but retain scaling and
  value/bit labels. Incompatible existing CSV headers fail. JSONL fields:
  timestamp/name/address/kind, plus value.
- `logger_sample`: `{values:[[raw,...],...]}` in the frozen row order. Validates
  shape/ranges, renders engineering values, throttles by monotonic interval,
  flushes the existing DataLogger. CSV writes one wide row; JSONL one per register
  row. Returns `{active,rows_written}`.
- `logger_status`, `logger_stop`: return `{active,rows_written}`; stop closes file.
  Disconnect/EOF/shutdown also close it. Flutter logging reads selected rows on a
  bounded timer, skips busy ticks and suppresses late samples after Stop.

`read_rows` evaluates each row's ordered alarm rules on its scaled primary value.
The result alarm contains condition/value/value2/color/log/sound, or null. Flutter
colors the map row, emits log/sound on alarm entry and logs recovery when the
previous rule enabled logging; recovery permits a subsequent entry. System sound availability depends on the Linux desktop.

Device modes:

- `device_start`: `{mode:"simulator"|"sniffer"|"gateway",listen,...}`. Listen
  uses `{transport,host,port,timeout}` for TCP/RTU over TCP or the RTU serial
  fields used by connect. Sniffer accepts RTU only. Simulator optionally accepts
  `unit` (null = any) and `tick_ms` 100..10000. Gateway requires `target` with the
  same connection schema (also rtu_udp), and `units` null or array 1..247.
  Validates parameters before stopping a previous service; startup errors are
  returned. One device service runs per process; its master backend is separate.
- `device_stop`: stops/join services and simulator rule timer.
- `device_status`: returns simulator/sniffer/gateway booleans, simulator rendered
  `rows`, sniffer `units`, drained bounded `events`, and `dropped` count. Events:
  `{mode,event:"traffic"|"values"|"client"|"error",...}` with line, unit,
  kind/address/values or connected as appropriate. Queue capacity 2000.
- `sim_configure`: `{rows}` replaces the simulator map descriptors/rules after
  full validation. Rows use the register schema, optional raw `values`, and
  `rule_text` (blank = manual). Addresses must fit 0..9999. Rules use the existing
  AST engine, references `[name]`, t/prev, rand()/randint(a,b). Missing references,
  nonfinite results and unrepresentable values skip writes. A process-owned
  timer applies rules independently of UI refresh.
- `sim_set`: `{row,values}` writes the simulator datastore, including while stopped.
- `sniffer_snapshot`: `{unit}` returns `{unit,areas:{kind:{address:value}}}` to
  recover values after event overflow. JSON address keys are strings.

Master `connect` additionally accepts `rtu_tcp` and `rtu_udp` with host/port.
Disconnect/EOF/shutdown stop all services, rule timers and logging. Switching a
Flutter session mode disconnects first; inactive tabs keep their services running.

Template commands:

- `template_list`: `{public:[{name,manufacturer,resource,description}],custom:[{id,name}]}`.
- `template_load`: public `resource` or custom `template_id` + optional `version_id`;
  returns `{state,template_id}` translated into disconnected Flutter session state.
- `template_save`: `{state,name}` creates a custom identity; `{state,template_id}`
  appends a snapshot even when unchanged. Returns `{id,name}`.
- `template_versions`: `{template_id}` → `{versions:[{id,saved_at}]}` newest first.
- `template_rename`: `{template_id,name}` changes display name only.
- `template_delete`: `{template_id}`; `template_delete_version`: adds `version_id`.
  Removing the final version fails. The Flutter UI confirms deletions.

Public catalog is shared/read-only. Custom histories reuse CustomTemplateStore in
`~/.modbus_connector/flutter/custom_templates`, isolated from Qt personal templates.
`MODBUS_FLUTTER_HOME` overrides that Flutter root for testing/portable deployments.
Flutter workspace files are schema 1 (`tabs`, `active_tab`, `language`, `theme_mode`)
and written atomically
by Dart to `flutter/settings.json`. They never include cloud settings/credentials,
never auto-connect, and do not overwrite Qt settings. Import is staged before
closing/replacing sessions. Corrupt startup state disables automatic overwrites.

`template_convert_workspace` accepts `{workspace: {tabs: [...], active_tab: n}}`
with 1..64 Qt session objects and returns a schema-1 Flutter workspace. It converts
connection/device modes, maps, expressions, simulator rules and recovered sniffer
values, inheriting Qt byte-order/grouping/column preferences. Only allowlisted
session fields survive; cloud settings/credentials and Qt custom-template IDs are
excluded. Conversion itself has no file or session side effects. The UI stages
and validates every converted session before replacing any live tabs.

Cloud/update commands:

- `cloud_settings_load` → `{settings}`; `cloud_settings_save`: `{settings}`.
  Settings are URL/username/password/templates_path/timeout/mode/remember_password.
  Separate `flutter/cloud.json`; plaintext password is omitted unless opted in.
- `cloud_start`: `{action,settings,version?}` starts a background task; actions
  test/download/versions/publish/activate. Publisher writes fail before network in
  consumer mode; activation requires a selected version. Publication snapshots
  only public templates, never sessions or personal templates. Returns started.
- `cloud_status`: `{running,action,error,result}`; result contains message,
  downloaded count, versions, or new version as appropriate. `cloud_cancel` sets
  cancellation immediately; current bounded HTTP completes before final status.
  Download/cache replacement and publication checkpoints use backend cancellation.
  UI waits for completion before closing. EOF cancels the task.
- Downloads validate the complete catalog before replacing
  `flutter/cloud_templates.json`; template-list/load overlays that cache. History
  download changes only local cache; activation appends a remote immutable version.
- `update_check` queries the latest stable GitHub release; returns current,
  release (tag/notes/installer metadata) or null, URL, newer, install_supported and
  install_reason. Network/rate-limit/invalid responses remain explicit errors.
- `update_open_page` opens only the known releases URL (or last verified tag URL)
  in the system browser, with child stdout/stderr detached from the protocol.
- `update_install` is not a backend command for launching an installer. The desktop
  update dialog owns `UpdateInstaller` and its cancellable async download; it accepts
  only the exact Flutter x64 NSIS asset for the release, with GitHub size and SHA-256.
  `install_supported` is true only for newer releases with a verified installer and
  a matching HKCU `ModbusConnectorFlutter` InstallLocation/executable.
- The workspace checks on startup when `auto_check_updates` is true (default).
  Background failures and unchanged versions stay quiet. Manual checks always show
  status. The setting follows workspace Save/autosave behavior.
- Installation requires explicit confirmation to save the workspace, close sessions
  and graph viewers, and restart. Failed saves abort the helper before shutdown.
  The PowerShell helper requires a commit marker and parent-process exit, checks
  for other instances and revalidates the SHA-256, runs NSIS `/S /D=<installDir>`,
  then restarts `modbus_desktop.exe`. Cancel/close waits for download cleanup;
  an uncommitted helper never installs. Linux and portable/source copies use manual
  download. There is no Python runtime dependency.

Workspace templates/cloud/update dialogs own a separate utility service so bus
transactions and polling in session tabs continue independently.

Advanced master commands:

- `mask_write`: `{unit,address,and_mask,or_mask}` invokes FC 0x16 with unsigned
  masks; `read_write`: `{unit,read_address,read_count,write_address,values}` invokes
  FC 0x17 (read 1..125, write 1..121 registers; both ranges validated).
- `diagnostics`: `{unit,action:"loopback"|"counters"|"clear",data?}` reuses FC 0x08
  backend functions. Missing/unsupported diagnostic counters are omitted.
- `evaluate_expressions`: `{expressions:[{name,text,alarms?}],values:{name:number}}`
  uses the shared safe AST engine without I/O. Returns `{rows:[{numeric,display,
  alarm,error}]}`; missing refs, nonfinite/math/parse errors produce a null numeric
  and per-expression error. Map polling reevaluates expressions and collects
  alarm/graph transitions. Persisted under session `expressions`.
- `scan_address` additionally returns `formats` (dec/hex/s16/u32/s32/f32/ascii).
  Checked scan hits can be inserted as independent register-map rows.

Cancellation acceptance checks cover map reads, alarm/graph side effects and late
errors, in addition to the master quick-range and logger generation checks.

Grouped and scheduled map reads:

- `plan_reads`: `{rows,unit}` → `{groups:[[row_index,...],...]}` uses the existing
  `plan_grouped_reads`, grouped by effective unit/area and adjacent/overlapping
  addresses, capped at protocol limits. Rows with `poll_ms` stay individual.
- `read_rows` accepts `grouped:true`; executes shared plans, slices raw results
  back into the original row order and renders each row's settings independently.
  Failed merged requests retry the member rows individually.
- Flutter submits one planned group at a time so cancellation is checked between
  transactions. Per-row `poll_enabled` gates manual/map polling; optional `poll_ms`
  100..86400000 overrides the map interval. Busy ticks are skipped. Group choice
  and row scheduling preferences persist in Flutter state/custom snapshots.

Display and simulator parity additions:

- `render_rows`: `{rows,unit?}` renders 1..4096 register descriptors containing
  raw `values`, using the same display/scaling/names/bitmask/alarms code as reads.
  Returns `{rows:[{values,display,numeric,alarm}]}` without bus I/O. Raw lengths
  and ranges are validated before rendering. Sniffer multiword views assemble
  consecutive recovered words in one area; incomplete views stay unavailable.
- `sim_configure` now retains invalid expression text as an inactive row rule
  instead of rejecting otherwise valid maps. Returns `rule_errors`, indexed by
  string row index, containing `{code,detail}`. Structural/raw/address validation
  still fails atomically. `device_status` also returns `rule_errors`: codes are
  `invalid_rule`, `missing_reference`, `nonfinite_rule`, `rule_evaluation_failed`.
  An invalid/failed row never writes; valid rows continue ticking. Evaluation
  errors clear on successful recovery; reconfiguration resets rule state.

Native file choosers, snapshot JSON exchange and graph PNG export are handled
locally by Flutter; they introduce no Python bridge commands or shared CSV schema changes.

Expression logger extension (canonical register-map CSV is unchanged):

- `logger_start` additionally accepts `expressions:[{name,text,alarms?}]`. The
  total selected register and expression columns must be 1..512; `rows:[]` is
  allowed for expression-only logging. CSV columns append `fx <name>` after the
  register columns and participate in the existing append-header check.
- `logger_sample` accepts `expression_values:{name:scaled_number}`, evaluated
  through the same safe AST engine as map expressions. Flutter freezes selected
  descriptors and acquires fresh map dependencies during each sampling cycle,
  independently of the map dialog/timer. Cancellation is checked after each read.
  Missing/nonfinite/invalid expressions produce `—`, with per-expression error
  results in the returned `expressions` array; successful results drive graphs
  and alarms. Raw register samples retain their existing schema.
- JSONL expression samples reuse LogSample fields: name = expression name,
  kind = `expression`, address = zero-based index among selected expressions,
  value = formatted result. This kind identifies calculated values, not a Modbus
  address. The shared writer and register-map CSV parser/exporter are unchanged.

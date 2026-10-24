# Desktop bridge protocol v1

Run `python -u -m modbus_connector.flutter_bridge` using an interpreter with the
repository package installed. UTF-8 NDJSON over stdin/stdout; stderr is diagnostic
text. No listener, shell commands or Qt. Every request has an integer/string `id`
and a `command`. The client sends **one request at a time**. Every response has
`id`, `ok`, `connected`, and either `result` or `error` (`type`, `message`, optional
Modbus `exception_code`). Framing/JSON errors return `id: null`; a malformed request
never terminates the bridge. Frames are limited to 65,536 characters.

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
  existing simulator on an ephemeral loopback TCP port and connects the real
  `ModbusBackend`. Successful connects return `result.description`. Demo holding
  addresses 0–124 start at 100; input registers 0–124 animate; bits 0–1999 have
  seeded patterns. Other simulator addresses up to 9999 start at zero.
- `read`: unit 1–247, four canonical `RegisterKind` strings, **0-based PDU**
  address 0–65535, count 1–125 registers / 1–2000 bits; range cannot overflow.
  Returns `result.values` (integers/booleans) and `elapsed_ms`.
- `write`: coils or holding registers only. Non-empty `values`, bool/0/1 coils,
  unsigned 0–65535 registers, at most 1968 coils / 123 registers. Returns
  `elapsed_ms`. The Flutter MVP writes one row and rereads the selected range.
- `disconnect`: closes the backend and demo, keeps bridge alive for reconnect.
- `shutdown`: closes resources, acknowledges, exits. EOF also closes resources.

Synchronous backend calls execute serially in this separate process. Flutter's
async pipe streams keep the UI responsive. Poll ticks skip when busy, so no queue
builds up. Stop polling invalidates the outstanding read generation; Disconnect
also invalidates connection state immediately, waits for the current call, then
sends `disconnect`. A read error stops polling; a manual read can recover a live
connection. The request watchdog allows five configured timeouts plus ten seconds
for pymodbus retries/cleanup, then terminates the bridge. Window exit closes stdin,
allows three seconds for cleanup, then terminates the child if necessary.

Multi-session ownership: every tab launches its own bridge process. There is no
shared connection or session identifier. Closing one tab waits for its active
transaction and closes that process; other tabs continue independently.

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

- `read_rows`: `{unit, rows:[row,...]}` (1..512). Each row accepts `name`, `kind`,
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
  `mapping` (source column → canonical field), returns `{rows}`. Uses Qt's shared
  CSV parser. Essential fields: name/kind/address.
- `csv_export`: `{rows,columns?}` returns `{text}` using canonical CSV fields.
  Columns can be selected; no filesystem access in these commands.

Flutter reads/writes CSV files, retains raw named snapshots in the session, and
compares snapshots without issuing writes. The register map has independent named
rows and polling; the quick contiguous range remains available in the master view.

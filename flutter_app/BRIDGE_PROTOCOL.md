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

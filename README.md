# modbus_connector

<img src="https://raw.githubusercontent.com/cramen/modbus_connector/main/assets/icon.png" width="96" align="right" alt="Modbus Connector icon">

[Russian version: README_ru.md](https://github.com/cramen/modbus_connector/blob/main/README_ru.md)

**[Download ready-made builds for macOS / Windows / Linux → Releases](https://github.com/sytuacmdyh/modbus_connector/releases)**

**[Watch the video presentation (1.5 min, Russian subtitles) → docs/presentation.mp4](https://github.com/cramen/modbus_connector/blob/main/docs/presentation.mp4)** (music: “Carefree” Kevin MacLeod, incompetech.com, CC BY 4.0)

A PySide6 GUI application for debugging Modbus buses and developing Modbus
devices. Works with Modbus TCP and Modbus RTU via synchronous pymodbus clients;
all Modbus logic runs in a separate thread (QThread), so the GUI never freezes.

Release notes automatically summarize commits since the previous stable tag,
with one full changelog link. No per-version Markdown file is required.

## Features

- Multiple simultaneous connections in tabs: each tab is an independent
  session with its own connection, register table, log and scanner. Settings
  for all tabs persist between launches in
  `~/.modbus_connector/settings.json` (old single-session settings files keep
  working), and can also be saved to / loaded from an arbitrary JSON file via
  the File menu.
- Connection types: TCP (host, port, timeout), RTU (serial port, baudrate,
  parity, etc.; RTU by default) and **RTU over TCP / RTU over UDP** for
  RS-485↔Ethernet converters — all configured in the GUI.
- Slave mode / device simulator (the **Mode** combo in each tab): the tab
  turns into a Modbus server — TCP, RTU or **RTU over TCP**, answering one
  unit id or **any** — with an editable register map. Set values manually in
  the row's display format (0.1 for f32, plain text for ascii/ascii1 — they
  land in the datastore instantly), watch master writes flash the table and
  every request and client connect hit the log, or drive rows with expression
  rules recomputed on a
  configurable tick (`[name]` references, `t` seconds since start, `prev`
  previous value, `rand()`/`randint(a,b)`). Device templates fill the map in
  one click — handy for debugging masters and gateways without real hardware.
- Sniffer mode (the third **Mode** option): a passive Modbus RTU bus listener
  on a separate serial adapter (a "tap" on the same RS-485 line — pyserial
  opens the port exclusively, so it cannot share the master's port). It
  watches another master's traffic and rebuilds the register map from what it
  sees: one tab per unit id with an auto-filled table (editable names and
  display formats, change flashes, trend sparklines), a per-unit frame log, a
  live graph window and CSV export in the master-table format (the file
  imports back into a master tab as is). Serial RTU only — Modbus TCP cannot
  be sniffed.
- Gateway mode (the fourth **Mode** option): a transparent Modbus proxy. The
  **Listen** side (TCP, RTU over TCP or serial RTU) accepts masters and every
  request is forwarded to the **Target** device (any connection type: TCP,
  RTU, RTU over TCP/UDP) — any direction works, e.g. exposing a serial RTU
  device as Modbus TCP or sharing one serial port between several TCP
  clients. The **Units** field filters the served unit ids (empty = all
  1..247, "1, 5, 10-20" serves only those; other units get silence). Every
  transaction is logged; a target error surfaces to the master as Slave
  Failure (0x04) with the reason in the log.
- Device templates (the **Templates** menu): ready-made register maps and
  default connection settings for popular devices — Eastron SDM120/SDM630,
  EPEver Tracer-AN, Huawei SUN2000, Delta Electronics MS300/C2000 and
  16 Wiren Board devices (WB-MS/WB-MSW sensors, WB-M1W2, WB-MR6C/WB-MR2M/
  WB-MRWM2 relays, WB-MDM3/WB-MRGBW-D dimmers, WB-MAP3E/WB-MAP6S/WB-MAP12E
  energy meters, WB-MAI6/WB-MAI11/WB-MAO4 analog I/O, WB-MCM8, WB-MIR).
  Status, alarm and mode registers are annotated with value names and
  bitmasks from the vendor documentation — an error code shows up as
  "oH2 (17)" and alarm bitfields list the raised flags by name.
  Choosing a template opens a new tab
  with everything pre-filled — just press Connect.
- Register table: rows with a name, area type (coils, discrete inputs,
  holding/input registers), address and count; read and write values.
  Enter in the "New value" column sends the write command, Ctrl+R (Cmd+R on
  macOS) reads the current row; the whole table is keyboard-friendly.
- Rich value display: per-row formats (dec/hex/s16/u32/s32/f32/u64/s64/f64/
  ascii) with byte order variants (ABCD/CDAB/BADC/DCBA), scaling with offset
  and engineering units; a value that changed between reads flashes for a
  couple of seconds.
- Per-row Unit ID (rows can address different devices on the same bus) and
  per-row polling interval (slow and fast registers in one table).
- Live graphs ("Graph…" button, separate window): a trend sparkline per table
  row and a full plot window with multiple series, sliding-window/follow or
  manual zoom, and draggable markers with per-series min/max/avg.
- Background logging of polled values to a CSV or JSON Lines file ("Log to
  file" button), with a configurable set of fields.
- System/Light/Dark theme (pyqtdarktheme) from the View menu — graphs,
  sparklines, status colors and highlights all follow the theme.
- Filter box and one-click "Sort by address" for large tables. Table columns
  can be reordered by dragging the headers and shown/hidden via the header's
  right-click checklist; the layout persists between sessions.
- Per-row polling checkbox (leftmost column): unchecked rows are skipped by
  polling and "Read all" and are hidden from the graph window; manual reads
  and writes still work.
- Alarm rules ("Alarms…" button): per-row ordered rules (>, <, >=, <=, ==,
  !=, in/outside range — first match wins) highlight the value cell in red
  or yellow, write an event to the log and optionally play a siren sound
  when a rule starts matching (including escalation to a stricter rule).
- Value names (enum labels): a row can map numbers to names ("0=Stopped",
  "1=Running", also 0/1 for coils) — the value then displays as
  "Running (1)" and the write field becomes a dropdown that writes the chosen
  value in one click (works in both master and slave modes). A "Bitmask"
  checkbox switches the mode: the names label bits 0..15 of a u16 register,
  the value lists the set bits with a grouped binary word ("Running, Alarm
  (0000 0000 1010 0101)") and the write field becomes a button opening a
  16-bit checkbox dialog.
- Snapshot diff ("Snapshot"/"Diff…" buttons): remember the current raw values
  of all rows, then compare them with later reads in a separate window —
  changed rows are highlighted, an "Only differences" filter hides the rest,
  and "Take new snapshot" accepts the current values as the new baseline.
- Expressions (the fx toolbar button): a block of computed rows under the
  table — "[name]" references a row's scaled value, arithmetic, pi/e and
  functions (abs, sqrt, sin, min, max, clamp, …) are allowed; each expression
  has a trend sparkline, joins the graph window as an "fx name" series, can
  carry alarm rules like a regular row, and offers autocompletion (register
  names and functions) while typing.
- Advanced protocol functions: Mask Write Register (0x16), Read/Write Multiple
  Registers (0x17), Read Device Identification (0x2B) and serial-line
  Diagnostics (0x08) — via dedicated dialogs.
- Link visibility: transaction statistics in the status bar (count, errors
  with percentage, top error kind, average response time), human-readable
  Modbus exception names and a live connection indicator (green = alive,
  orange "(idle)" = link idle or degraded).
- Address scanner ("Scanner…" button, separate window): iterates unit ids in
  a given range with configurable probes and shows devices that answered at
  least one probe; double-click a found unit to select it for the connection.
  A second sweep scans the register address space of a known unit and lists
  the addresses that respond — together with the read values decoded in
  several columns at once (Bool for coils/discrete inputs; dec, hex, s16,
  u32, s32, f32 and ascii for registers).
- Log panel at the bottom of the window, toggled with the "Log" button:
  human-readable requests/responses, optional raw bus traffic in hex
  ("Raw" checkbox) and export of the whole log to a file ("Save…").
- A help button (a "?" icon with a tooltip) in each window (table toolbar,
  graph, scanner) opens a short help sheet with that window's controls and
  hotkeys; window toolbars use compact icon buttons with tooltips.
- Multilingual UI: English, Русский and 简体中文, switched live in View → Language
  (default follows the system locale; the choice persists).

## Screenshots

Main window (light and dark themes — the View menu switches them) — two
connection tabs, register table with read values and per-row trend
sparklines, log:

![Main window, light theme](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/main_window.png)

![Main window, dark theme](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/main_window_dark.png)

Live graph — multiple series in a follow window, zoom and draggable markers
with per-series min/max/avg (the "Graph…" button in the connection panel);
light and dark themes:

![Live graph, light theme](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/graph_window.png)

![Live graph, dark theme](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/graph_window_dark.png)

Per-row display settings — Scale/Offset/Unit and a byte-order override per
register row (the "Display…" button above the table):

![Display settings](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/display_dialog.png)

CSV export — choose which columns to write and their order (the "CSV" button
above the table):

![CSV export](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/export_dialog.png)

CSV import — map file columns to register fields before loading the table:

![CSV import](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/import_dialog.png)

Logging to a file — write polled values to CSV or JSON Lines: file, format,
field selection and a per-row checklist (the gear icon next to "Log to file"):

![Logging settings](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/logging_dialog.png)

Address scanner — unit sweep with probes and the register address scan:

![Scanner](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/scanner.png)

Snapshot diff — capture the current values, read again later and compare;
changed rows are highlighted:

![Snapshot diff](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/snapshot_diff.png)

Expressions — computed rows over register values, with trend sparklines
(the fx toolbar button):

![Expressions](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/expressions.png)

Slave mode — the tab as a Modbus device emulator: server parameters and an
editable register map with manual values and expression rules (the "Mode"
combo above the table):

![Slave mode simulator](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/simulator.png)

Sniffer mode — passive listening of a Modbus RTU bus through a separate
serial adapter: one tab per unit id, auto-filled value table with trends,
per-unit frame log:

![RTU sniffer](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/sniffer.png)

Gateway mode — a transparent Modbus bridge: masters connect to the Listen
side (TCP, RTU over TCP or serial RTU), every request is forwarded to the
Target device, with an optional unit-id filter and a transaction log:

![Gateway mode](https://raw.githubusercontent.com/cramen/modbus_connector/main/docs/screenshots/gateway.png)

## Command-line utility (modbus-connector-cli)

Alongside the GUI the package ships a non-interactive CLI built for scripts,
CI pipelines and headless servers. It needs **no Qt** — a lean install pulls
only pymodbus:

```bash
pip install modbus-connector        # CLI only (no Qt)
pip install "modbus-connector[gui]" # CLI + GUI
```

Ready-made standalone binaries (`modbus-connector-cli-macos` /
`-linux` / `-windows.exe`, no Python needed) are attached to
[Releases](https://github.com/sytuacmdyh/modbus_connector/releases).

For LLM agents there is a companion **MCP server**
([`modbus-connector-mcp`](mcp/README.md), `pip install
modbus-connector-mcp`): the same reads/writes, scanners, simulator,
gateway and sniffer exposed as MCP tools over stdio, with non-blocking
jobs for long-running processes and an optional `--read-only` mode.

Output is **JSON-first**: structured JSON (or NDJSON for streaming commands)
goes to stdout, diagnostics to stderr; `--text` switches to human-readable
output. Exit codes: `0` ok (including Ctrl+C of streaming commands),
`2` connection error/timeout, `3` Modbus exception from the device,
`4` bad arguments/input files. Every subcommand has a `--help` with working
examples.

```bash
# one-shot read / write
modbus-connector-cli read --tcp 192.168.1.10:502 --unit 1 hr 200 6 --format f32
modbus-connector-cli write --rtu /dev/ttyUSB0 --baud 9600 coil 3 1

# polling: NDJSON stream to stdout and/or a CSV/JSONL log file, Ctrl+C to stop
modbus-connector-cli poll --tcp 192.168.1.10 hr 0 10 --interval 1000 --log out.csv
modbus-connector-cli poll --tcp 192.168.1.10 --map "Eastron/SDM120 template export.json"

# scanners: unit ids / register address space
modbus-connector-cli scan units --rtu /dev/ttyUSB0 1-10
modbus-connector-cli scan addresses --tcp 192.168.1.10 --unit 1 hr 0-100

# headless device simulator (map = template/session JSON or table CSV)
modbus-connector-cli simulate --map device.json --tcp 1502

# headless gateway: listen side and target side accept tcp:/rtu:/rtuovertcp: specs
modbus-connector-cli gateway --listen tcp:5020 --target rtu:/dev/ttyUSB0,baud=9600 --units "1,5"

# passive RTU sniffer: decoded frames and values as NDJSON
modbus-connector-cli sniff --rtu /dev/cu.usbserial-1420 --baud 19200
```

## Requirements

- Python 3.11+

The base package (CLI) depends only on `pymodbus[serial]==3.6.9` — the
Modbus TCP/RTU protocol stack (synchronous clients); the `serial` extra
brings `pyserial` for RTU ports.

GUI dependencies (extra `[gui]`, installed automatically by
`pip install "modbus-connector[gui]"` and baked into the standalone
bundles):

- `PySide6==6.10.3` — Qt 6 GUI framework; pinned to avoid the 6.12.0
  Python 3.11 reference-count crash; the full meta-package including Addons
  (QtMultimedia is used for the alarm sound)
- `pyqtgraph` — live register graphs (pulls in `numpy`)
- `pyqtdarktheme` — light/dark/system themes

Optional extras:

- `pip install -e .[dev]` — full development environment (Qt stack, `pytest`,
  `pytest-asyncio`, `ruff`)
- `pip install -e .[build]` — `pyinstaller>=6` (standalone app bundles)

## Installation

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e .[dev]
```

## Run

```bash
modbus-connector
# or
python -m modbus_connector
```

## Usage

### Connecting

1. Choose the connection type: **TCP** (host, port), **RTU** (serial port,
   baudrate, data bits, parity, stop bits — RTU is the default; use "Refresh"
   to rescan serial ports) or **RTU over TCP** / **RTU over UDP** (host, port —
   RTU frames inside a network socket, for RS-485↔Ethernet converters such as
   USR or Elfin).
2. Set the **Unit ID** of the target device (used for all register operations)
   and the response **Timeout**.
3. Press **Connect**. Input fields are locked while connected; press
   **Disconnect** to change settings.

Serial RTU clients wait for the requested response bytes within the configured
serial timeout, without pymodbus's strict inter-byte timeout. This avoids
premature short reads between USB adapter packets on Windows; RTU frame length
and CRC checks remain enabled.

The status label next to the button is live: green means the link is up,
orange with an "(idle)" suffix means the connection is configured but the last
transaction timed out — pymodbus reconnects transparently on the next request,
so this is informational, not an error. The status bar at the bottom of the
window shows transaction counters: total, errors with a percentage and the
most frequent error kind (the full breakdown by error type is in the label's
tooltip), plus the average response time of successful operations. Modbus
exception responses are reported by name (e.g. "Illegal Data Address (0x02)")
in the log.

### Working with tabs

The main window holds connections in tabs. The **+** button in the tab bar
corner opens another independent session — its own connection, register table,
log and scanner window. The tab title follows the connection (e.g. `tcp
192.168.1.10:502`); the last remaining tab cannot be closed. The status bar
statistics follow the active tab. All tabs are saved to the settings on exit
and restored on the next launch — including each table's column widths. The
**View** menu switches the theme (System/Light/Dark); the choice is app-wide
and is saved with the settings.

### Device templates

The **Templates** menu (between File and View) separates **Public templates**
(bundled templates and cloud downloads, grouped by manufacturer) from local
**Custom templates**. Choosing one opens a **new tab** with the
connection settings and the register table pre-filled from the template —
press **Connect** and read. The tab keeps the template's name until the
session connects.

Use **Templates → Save as custom template…** to save the current session under
a personal name. Public templates cannot be overwritten: edit their session and
save a custom copy. **Save new version** appends a snapshot every time, even
when nothing changed. The session retains its custom-template association across
app restarts. **Manage custom templates…** lists versions newest first, shows
save times in the local timezone, opens any version in a new disconnected tab,
and supports renaming or deleting a template and deleting individual versions.
To return to an old version, open it and save a new version. Deleting the latest
version makes the preceding version current; to remove the last version, delete
the entire template. Deletions require confirmation and do not close open tabs.

Custom templates preserve session settings, register annotations, expressions and
simulator rules. They are stored separately in
`~/.modbus_connector/custom_templates/<id>.json`; each file contains its display
name and all UTC timestamped snapshots, replaced atomically on save. Renaming
does not rewrite snapshots. Cloud template downloads and publication never
modify or publish this personal catalog. Simulator template menus expose both
catalogs and import the simulator map when the saved session is in Slave mode.

For developers adding a bundled public template, place a JSON file in
`src/modbus_connector/templates/<Manufacturer>/<Device>.json`:

```json
{
  "name": "My Device",
  "description": "optional text, shown as the menu item tooltip",
  "connection": {"type": "RTU", "rtu_baud": "9600", "unit": 1, "timeout": 3.0},
  "registers": [
    {"name": "Voltage", "kind": "input_registers", "address": 0, "count": 2,
     "format": "f32", "unit": "V"}
  ]
}
```

`connection` accepts the same keys as the saved settings (`type` — TCP/RTU/
RTU over TCP/RTU over UDP, `tcp_host`/`tcp_port` or `rtu_baud`/`rtu_bytesize`/
`rtu_parity`/`rtu_stopbits`, `unit`, `timeout`); each register row takes
`name`, `kind`, `address` (0-based PDU address), `count`, `format` and the
optional `order`, `scale`, `offset`, `unit` — the same fields as the table
columns. A row may also carry `value_names` (`{"0": "Stopped", "1": "Running"}`
— enum labels shown as "Running (1)", also for coils) and `bitmask: true`
(names then label bits 0..15 of the register). See any bundled file (e.g.
`templates/Eastron/SDM120.json`) for a full example.

### WebDAV cloud sync

Open **File → Cloud sync…** and enter your own WebDAV folder URL, account and
a relative template folder (default: `templates`). The dialog groups connection
settings, template sync and template history separately. Only public templates
are synchronized; session configurations are not uploaded or restored.
Choose a local mode:

- **Consumer** (default): test the connection, update templates, browse template
  history and download a selected historical version.
  Publish/rollback controls are hidden; the sync backend also rejects
  write operations in this mode. Use a WebDAV account with read-only access.
- **Publisher**: all consumer actions plus **Publish local templates** and
  **Set as current cloud version…**. Use an account with write
  access. Changing the mode never changes the server account's permissions.

**Publish local templates** publishes every template in the current local
catalog (bundled templates with downloaded overrides), after confirmation.
Each publication archives a complete JSON catalog in
`templates/.versions/<version>.json`, then updates `templates/.catalog.json`.
Readers validate the complete catalog before updating their local cache. Failed
snapshot uploads leave the current catalog unchanged, and archived versions
remain available if updating the current file fails. Removing a local template from a subsequent
publication removes it from the cloud catalog; bundled templates remain usable
locally. Empty publications are rejected to prevent accidental catalog clearing.
If no published catalog exists, legacy `templates/<Manufacturer>/<Device>.json`
folders remain supported. Templates use the same JSON schema as bundled files.
Updates refresh both the main and simulator template menus and remain available
offline in `~/.modbus_connector/cloud_templates.json`.

In **Template history**, click **Load history**, select a version and choose
**Use selected templates** to use it locally. Version actions remain disabled
until a version is selected. Publishers can also **Set as current cloud version…**
for everyone, after confirmation. Rollback creates a new version and preserves
the existing history. Versions use a UTC
timestamp and random suffix. Concurrent publishers use last-completed-write wins.
A snapshot whose current-file update failed can still appear in history.

All transfers are manual and run in the background. Closing the dialog requests
cancellation and waits for the current request to finish or time out. Failed or
cancelled template downloads preserve the previous local cache. Limits: 1,000
templates and 16 MiB per response or complete catalog. Redirects are rejected;
TLS verification remains enabled.

WebDAV settings live separately in `~/.modbus_connector/cloud.json`. Passwords
are not saved by default. **Remember password on this computer (plain text)**
explicitly opts into storing the password in this local JSON file. The application
has no Windows Credential Manager integration. A connection previously saved only
in Credential Manager requires entering the password again. File-menu exports
never include cloud credentials or mode. Legacy
`configuration_path` settings are ignored and omitted when connection settings
are saved; existing remote configuration files are not modified.

### Adding registers

Press **Add register** and fill in the row: an arbitrary **Name**, the area
**Type** (coils, discrete inputs, holding registers, input registers),
**Address** (decimal or hex, e.g. `0x10`) and **Count** (how many values to
read starting at the address). The optional **Unit ID** column overrides the
connection-wide unit for this row (empty = use the connection unit) — handy
for polling several devices on one RS-485 bus. All columns are plain cells —
the table is fully navigable with the keyboard. The ✕ button deletes a row.

### Reading values

- **Ctrl+R** (**Cmd+R** on macOS) — reads the row that has the keyboard focus;
  **Ctrl+Shift+R** reads every row (the "Read all" button).
- Quick actions on the focused row (also in the table's right-click menu):
  **Ctrl+C** copies the value, **Ctrl+0**/**Ctrl+1** write 0/1,
  **Ctrl+=** (or numpad **Ctrl++**)/**Ctrl+-** step the last read value,
  **Ctrl+T** toggles it
  (coils flip the bit; a register goes 0↔1). Writes use raw values, so
  scaled/hex displays stay safe; input/discrete areas report "read-only".
- **Ctrl+Up**/**Ctrl+Down** move the selected rows as a block (multi-selection
  works); the row order persists with the session.
- **Read all** — reads every row once.
- **Start polling and record** — a split button: the main action reads all
  rows repeatedly with the interval set in the "Interval" field
  (milliseconds) and records value history; press **Stop polling** to stop.
  The dropdown offers **Start polling** (without recording) and **Start
  polling and record** — picking one while polling runs switches the
  recording mode on the fly, and the last choice becomes the main action.
  The optional **Poll, ms** column overrides the interval per row (empty =
  global interval; finer values are effectively clamped to the global tick).
- **Group reads** — enabled by default: rows of the same effective unit and area type with
  contiguous or overlapping addresses (no gaps) are merged into a single Modbus
  request and the response is split back across the rows; if a grouped read
  fails, the affected rows fall back to individual reads. The failed block stays
  on individual reads until polling stops or the connection/unit changes. Saved
  `group_reads: false` settings continue to disable merging. Requests are capped
  at 125 registers or 2000 bits; devices may impose smaller limits.

Read values appear in the **Value** column; every request and response is also
shown in the log panel (toggled with the "Log" button). Bus-reading controls
(Read all, polling, logging, the 0x16/0x17 dialogs and the scanner's Start
buttons) are enabled only while a connection is up — dropping the connection
stops polling and logging.
Clicking **Disconnect** immediately stops polling and cancels queued bus requests.
The current transaction finishes or times out before the connection closes; the
status shows **Disconnecting…** while it waits. Closing the session also cancels
queued requests instead of waiting for every register to time out.
**Stop polling** also cancels queued reads and discards late results and error
logs from the stopped batch. The active transaction may still finish or time out
internally; the connection stays open for manual reads or restarting polling.
Backend error messages and common timeout details follow the selected UI language.

Only the current table row creates its Type/Format dropdowns, enum or bitmask
editor, and delete button. Other rows display stored text; selecting a row does
not change its polling checkbox or trend setting. Trend lines are painted directly
in visible cells without a widget per row.

### Display formats, scaling and units

For register rows the **Format** column chooses how the Value column renders:
`dec` (default), `hex` (`0xNNNN`), `s16` (signed 16-bit), `u32`/`s32`/`f32`
(pairs of registers as one 32-bit value), `u64`/`s64`/`f64` (groups of four
registers) and `ascii` (two characters per register, e.g. device names and
serial numbers; the string ends at the first NUL byte). Coils and discrete
inputs always show 0/1.

Multi-register values are big-endian by default (the first register is the
high word); the **Order** combo above the table sets the byte layout for all
rows (`ABCD` default, `CDAB` word-swapped, `BADC` byte-swapped words, `DCBA`
full reverse), and a per-row override is available in the **Display…** dialog.
A leftover register that does not fill a whole 32/64-bit group is shown as-is.

The **Scale**, **Offset**, **Unit** and per-row **Order** settings live in the
**Display…** dialog above the table (one row per register row). The raw
registers are first decoded according to Format and Order, then each decoded
number is displayed as `x * scale + offset` with the unit appended
(e.g. `23.5 °C`). Scaling is skipped for the `hex` and `ascii` formats.
Table columns can be resized by dragging the header separators.

A value that changed since the previous read flashes green for ~2 seconds.

Use the **Filter…** box above the table to show only rows whose name, type,
address or unit id contains the text, and **Sort by address** to reorder the
table by address.

### Writing values

Type the value(s) into the **New value** column and press **Enter** — the
write command is sent immediately. Values are always raw: display scaling
(Scale/Offset) is never applied to them.

- registers: decimal or hex numbers (`4321`, `0x10E1`); for Count > 1 enter
  several values separated by commas or spaces (`1, 2, 0xFF`) — a single value
  uses function "write single register", several values use "write multiple
  registers";
- coils: `0`/`1`, `true`/`false`, `on`/`off` (case-insensitive).

After a successful write the row is re-read automatically, so the **Value**
column reflects the applied change. Parse errors and Modbus errors are
reported in the log panel.

Note: only coils and holding registers are writable — discrete inputs and
input registers are read-only by the protocol.

### Advanced protocol functions

- **Mask write (0x16)…** (button above the table) — Mask Write Register:
  AND/OR masks applied to one holding register, setting or clearing individual
  bits without touching the others. Table rows covering the address are
  re-read after a successful write.
- **Read/Write (0x17)…** — Read/Write Multiple Registers: writes values and
  reads back a range in one atomic transaction (no race window); the returned
  values go to the log.
- **Device ID…** (connection panel, enabled while connected) — Read Device
  Identification (0x2B/0x0E): vendor name, product code, revision and other
  objects reported by the device.
- **Diagnostics…** (connection panel, enabled while connected) — serial-line
  diagnostics (0x08): loopback echo check and bus/slave message counters with
  Refresh and Clear counters. This is a serial-line function, but some TCP
  devices answer it too.

### Scanning for devices

Press **Scanner…** to open the scanner window. Set the unit id range
(default 1–247) and the probe list (register type + address + count to try on
each address; sensible defaults are prefilled). **Start scan** begins the
sweep, **Stop** aborts it; units that answered at least one probe appear in
the results list. **Double-click a found unit** to copy it into the connection
panel's Unit ID field. Scanning pauses polling in the main window.

The **Registers scan** section below works the other way around: for a known
unit it reads a range of addresses of a chosen register type one by one and
lists every address that answered as `0xNNNN (dec)` — a quick way to map the
register space of an unfamiliar device. **Add selected to table** turns the
checked addresses into register rows (all hits are checked by default;
duplicates are skipped), and **Device ID…** reads the selected unit's
identification (0x2B/0x0E).

The scanner's range, probe list and address-scan parameters persist in the
settings along with everything else.

### Graphs

Rows with **Trend** enabled capture their value history while polling runs in the
poll-and-record mode (scaled engineering value; hex/ascii rows are skipped)
and show it as a small trend sparkline in the **Trend** column. The buffer
is bounded to ~10k samples per row; when recording is off, sparklines and
graph curves freeze on the last recorded data. **Graph…** (connection panel)
opens the full plot window.

Use **Display… → Trend** to enable history per row, or right-click selected rows
and choose **Enable trend / Disable trend** for a batch change. **Enable trends
by default** controls rows without an explicit override. Disabling a trend stops
history collection and hides that row from the graph while reads, values, alarms,
expressions and file logging continue. Existing history is retained until cleared.
Older settings without a trend option keep trends enabled.

JSON templates and saved sessions support a default and per-row overrides:

```json
{
  "registers_options": {"group_reads": true, "trend_enabled": false},
  "registers": [
    {"name": "Supply temperature", "kind": "holding_registers", "address": 100,
     "count": 1, "trend_enabled": true}
  ]
}
```

The EMS template enables contiguous reads and disables trends by default; enable
the operating values you want to record. Import/export preserves these settings
in JSON; CSV keeps its existing column format.

The graph window provides these controls:

- the **Series** checklist on the left picks which table rows are plotted
  (new rows join checked by default);
- **X scale: Follow** slides a window of the given width along the latest
  data, **Full** fits everything, **Manual** freezes the view — zooming or
  panning (wheel at cursor, left-drag, or the **Zoom rect** toggle) switches
  the mode to Manual so the change is visible; **Reset view** returns to
  Follow;
- **Markers** shows two draggable vertical lines (green A, red B) and a stats
  table with per-series min/max/avg between them plus Δt, updated live;
- hovering the plot shows a crosshair: a dashed vertical line at the cursor's
  time and a top-right readout with every series' value at that moment
  (nearest recorded sample, marked with a dot on each curve);
- **Clear** empties the recorded history and restarts the relative time
  axis (markers are re-placed once new data arrives); right-clicking a Trend
  cell in the table offers the same "Clear history";
- **Start polling and record** duplicates the table's poll control: starts
  polling with recording (or just enables recording if polling already runs),
  turns into **Stop polling** while recording is active.

Closing the graph window only hides it; the data stays.

### Logging values to a file

The **Log to file** button above the table writes every read value to a file
while it is on; starting it also starts polling if it wasn't running (with
history recording if the split button's mode is "and record"). The gear
button next to it opens the settings: the file (a timestamped name in the
home directory is suggested), the format, which optional fields —
timestamp (wall clock, ISO 8601 with milliseconds), row name, register
address and register type — accompany the value, and which table rows get
logged at all (the "Rows to log" checklist; new rows join logged by default,
and the per-row choice persists with the session). Values are
machine-friendly: decoded numbers with scale/offset but without the unit,
multi-value rows joined with ";", coils/discrete inputs as 0/1, hex/ascii
rows as displayed.

Formats: **CSV** (one row per read, a header row in new files) and **JSON
Lines** — one JSON object per line, which streams and appends cleanly.
Appending to an existing file is the default; the settings (not the on/off
state) persist with the session. Stopping logging leaves polling running.

### Log panel
The log panel at the bottom of the main window (toggled with the **Log**
button) shows every request and response with timestamps. The **Raw**
checkbox additionally displays raw bus frames in hex (`→ tx …` / `← rx …`) —
off by default to keep the log readable. **Save…** exports the entire log
(including raw frames hidden by the checkbox) to a text file; **Clear**
empties it.

### CSV import/export

The **CSV** drop-down above the table exchanges the register table with
spreadsheet tools:

- **Import table…** loads a CSV file and *replaces* the whole table. A
  mapping dialog appears first: every file column can be matched to a
  register field (name, kind, address, count, unit_id, poll_ms, format,
  scale, offset, unit, order) or skipped; matches are guessed from column
  names ("type" counts as kind) and the essential fields name/kind/address
  must be mapped. Errors are reported in the log, an invalid file leaves the
  table untouched.
- **Export…** opens a column chooser first — check which columns to write
  and reorder them (arrows/Space/Ctrl+Up/Ctrl+Down) — then writes the CSV:
  the chosen columns plus an optional `value` column with the currently
  displayed (formatted/scaled) text — readable as a report and re-importable:
  the `value` column is simply skipped by default in the mapping dialog, so
  the round trip "export → edit in Excel → import" works out of the box.

Only `name`, `kind` and `address` are required on import — unmapped optional
fields fall back to defaults. Files are written UTF-8 with BOM so Excel opens
them cleanly.


## Checking for updates and publishing releases

Use **Help → Check for updates…** to check the latest stable release in
[sytuacmdyh/modbus_connector](https://github.com/sytuacmdyh/modbus_connector/releases).
The check runs in a background thread and shows the current version, available
version and release notes. **Download update…** opens the release page in your
browser; choose the package for your OS and install it manually. On Windows,
download **`modbus-connector-<version>-windows-x64-setup.exe`** for the installer
(start menu shortcuts and uninstall entry; no administrator rights required).
Exit the application before updating. **`modbus-connector-windows.zip`** is the
portable alternative: extract it and run `ModbusConnector/ModbusConnector.exe`.
ZIP users should replace the whole application folder when updating.
Settings remain in `~/.modbus_connector/`. Checking never uploads settings.

The public GitHub API requires no token. Drafts and prereleases are excluded.
A missing release, network failure or API rate limit is shown explicitly, and
you can retry. Checks are manual; the application does not check on startup.

To publish an update, commit your changes on `main`, fetch and integrate any
remote updates, then run the release script with the next stable version:

```bash
python packaging/release.py 0.15.1 --dry-run  # validate without changing local or remote state
python packaging/release.py 0.15.1            # publish and wait for the complete release
python packaging/release.py 0.15.1 --status   # check an existing release
```

The script needs Python 3.11+ and Git push access to the GitHub `origin` remote;
no extra Python packages or GitHub CLI are required. Use `--remote NAME` to
select another remote with matching fetch/push URLs. It refuses uncommitted
changes, remote history missing locally, older versions and duplicate tags.
It updates `__version__` in `src/modbus_connector/__init__.py` (the single source
for package and GUI versions), commits the version change, creates an annotated
`vMAJOR.MINOR.PATCH` tag, then atomically pushes `main` and the tag without force.
CI runs the tests and creates the packages. The script waits up to 30 minutes and
only reports completion when the matching tag build succeeds, release notes are
present and all 12 expected assets are uploaded, including the Windows installer.
`--no-wait` returns after pushing; `--timeout SECONDS` changes the wait limit.
An optional `GH_TOKEN` or `GITHUB_TOKEN` raises the API rate limit; tokens are never
required for public status checks or printed by the script.

If pushing fails after local preparation, fix the cause and run
`python packaging/release.py 0.15.1 --resume`. This reuses the local commit/tag
only if the version and current `HEAD` match; remote tags are never overwritten.
If CI fails or the wait times out, inspect the printed Actions link and use
`--status` to check again. Do not move a published tag to a different commit.

The existing `.github/workflows/build.yml` verifies the
tag matches the application version, builds Windows/macOS/Linux packages, and
attaches them to GitHub Releases. Release notes automatically summarize commits.
The Windows job builds and tests an NSIS installer as well as the portable ZIP.
`windows-installer.yml` can also add a missing installer to an existing release
using its published ZIP; existing assets and release notes are preserved.
The update checker uses this fork's releases, rather than the upstream project.

## Building a standalone executable

```bash
./build.sh        # macOS / Linux
build.bat         # Windows (cmd, also works by double-click)
```

The script installs PyInstaller (the `build` extra) and builds a standalone
application into `dist/`: on macOS — `ModbusConnector.app` plus a
`ModbusConnector.dmg` disk image; on Windows/Linux — a `ModbusConnector/`
folder with the executable inside (`ModbusConnector.exe` on Windows; copy the
whole folder to another machine). The artifact does not require Python on the
target machine.

To create a Windows installer after `build.bat`, install NSIS and run
`python packaging/windows/build_installer.py`. The output is
`dist/modbus-connector-<version>-windows-x64-setup.exe`. Installation defaults to
`%LOCALAPPDATA%\Programs\ModbusConnector`; uninstall retains user settings and
custom templates in `~/.modbus_connector/`.

macOS notes:

- Run: double-click `ModbusConnector.app` or `open dist/ModbusConnector.app`.
  Never run files from the intermediate `build/` directory (the script removes
  it after building).
- To move the app to another machine use the ready-made
  `dist/ModbusConnector.dmg` (do not rename or repack the `.app` into a `.pkg`
  yourself — such a file is not a valid installer).
- The app is ad-hoc signed: on another Mac Gatekeeper will warn about an
  unidentified developer on first launch — open via right-click → "Open", or
  remove the quarantine: `xattr -dr com.apple.quarantine ModbusConnector.app`.

Linux notes:

- RTU connections to serial ports (`/dev/ttyUSB*`, `/dev/ttyACM*`, etc.) require
  membership in the port's group, usually `dialout` (sometimes `uucp`). If you
  see `Errno 13` / "Permission denied" on connect, check the port:
  ```bash
  ls -l /dev/ttyUSB0
  ```
  Add your user to the group and re-login (or run `newgrp dialout`):
  ```bash
  sudo usermod -aG dialout $USER
  ```

## Project layout

```
src/modbus_connector/
  models.py       # Qt-free data types and helpers: TcpParams/RtuParams/
                  # RtuOverTcpParams/RtuOverUdpParams, RegisterRow, ScanProbe,
                  # DisplayFormat, ByteOrder, describe_connection(),
                  # parse_values()/format_values(),
                  # format_register_values()/format_scaled_values(),
                  # EXCEPTION_CODES/describe_exception(), Stats/StatsSnapshot
  backend.py      # ModbusBackend — synchronous pymodbus wrapper (no Qt):
                  # read/write, mask write (0x16), read/write registers (0x17),
                  # device identification (0x2B), diagnostics (0x08),
                  # unit scan, register address scan, raw traffic hook
  worker.py       # ModbusWorker (QObject) — signals/slots over backend, QThread;
                  # timing statistics, liveness checks, traffic forwarding
  sim_backend.py  # SimBackend — pymodbus Modbus slave server (TCP/RTU) for
                  # the slave mode: value blocks, master-write/request/client
                  # hooks
  sim_worker.py   # SimWorker (QObject) — signals/slots over SimBackend in a
                  # QThread; rule ticker for the simulator
  sim_panel.py    # slave-mode panel: server parameters, editable register
                  # map with manual values and expression rules
  sniffer_backend.py  # passive Modbus RTU bus sniffer (no Qt): own frame
                      # parser with CRC16 resync, tx/rx direction heuristics,
                      # bus model; SnifferBackend with value/frame/error hooks
  sniffer_worker.py   # SnifferWorker (QObject) — signals/slots over
                      # SnifferBackend in a QThread
  sniffer_panel.py    # sniffer-mode panel: serial parameters, per-unit tabs
                      # with an auto-filled value table (trend sparklines),
                      # per-unit frame logs, live graph, CSV export in the
                      # master-table format
  gateway_backend.py  # GatewayBackend — transparent Modbus gateway (no Qt):
                      # a pymodbus listen server (TCP / RTU over TCP / RTU
                      # serial) forwards every request to the sync
                      # ModbusBackend target; units filter, request/error/
                      # client hooks
  gateway_worker.py   # GatewayWorker (QObject) — signals/slots over
                      # GatewayBackend in a QThread
  gateway_panel.py    # gateway-mode panel: Listen and Target parameter rows
                      # (ConnectionPanel-style type combo + network/serial
                      # pages), Units filter, Start/Stop gateway, client count
  connection_panel.py  # connection panel (TCP/RTU/RTU over TCP/RTU over UDP,
                       # state/set_state) with a live status indicator
                       # (gray/green/orange); Device ID…/Diagnostics… dialogs
  registers_panel.py   # register table: per-row unit/poll/format/order/scaling,
                       # change highlighting, filter/sort, Enter = write,
                       # Mask write…/Read/Write… dialogs, alarm rules,
                       # snapshot diff
  alarms_dialog.py     # per-row alarm rule editor (condition, color, log, sound)
  alarm_sound.py       # alarm siren: generated two-tone WAV + QSoundEffect
  snapshot_dialog.py   # non-modal window comparing a value snapshot with
                       # current reads (highlighted differences)
  scanner_panel.py     # unit scanner + register address scan (separate window)
  log_panel.py         # log panel (hideable): Raw hex traffic toggle, Save…
  settings_store.py    # settings persistence in ~/.modbus_connector/settings.json
  cloud_sync.py    # Qt-free WebDAV client, local cloud settings, atomic template cache
  cloud_dialog.py  # connection setup, background template sync and template history
  custom_templates.py  # Qt-free local custom templates and timestamped versions
  custom_templates_dialog.py  # rename/delete templates, browse/open/delete versions
  template_menu.py  # shared public/custom menu grouping
  templates/      # bundled device templates: <Manufacturer>/<Device>.json
                  # register maps + default connection settings (package data,
                  # read via importlib.resources; loader in templates/__init__.py)
  session_widget.py # SessionWidget — one Modbus session (panels, scanner
                    # window, worker thread) as a self-contained widget
  main_window.py  # main window: sessions in tabs, File/Templates/View menus,
                  # status bar following the active tab
  app.py          # QApplication creation and startup
  __main__.py     # python -m modbus_connector
tests/
  conftest.py     # modbus_server fixture: test Modbus TCP server on 127.0.0.1
  test_models.py  # value parsing/formatting, exceptions, Stats
  test_backend.py # ModbusBackend against the test server
  test_registers_panel.py  # offscreen Qt tests for the register table
  test_session_widget.py   # session state round-trip and shutdown
  test_main_window_tabs.py # tab lifecycle and settings round-trip
```

## Development

```bash
pytest          # tests
ruff check .    # lint
```

The backend tests start a real Modbus TCP server (pymodbus) on 127.0.0.1
with a free port and exercise read/write/scan through `ModbusBackend`.

## CI

GitHub Actions (`.github/workflows/build.yml`) runs tests and builds artifacts
for all three OSes on macOS/Windows/Linux runners on every push to `main`:
`modbus-connector-macos` (DMG), `modbus-connector-windows` (zip),
`modbus-connector-linux` (zip) and `modbus-connector-linux-packages`
(AppImage + deb). Download them from the
workflow run page (Actions → a run → Artifacts; kept for 90 days); a build can
also be started manually via "Run workflow".

Pushing a `v*` tag (e.g. `git tag v0.1.0 && git push origin v0.1.0`)
automatically attaches the same files to a GitHub Release — a permanent
download page (Releases in the repository). PyPI publishing is limited to
the upstream `cramen/modbus_connector` repository; forks publish GitHub Releases.
On Linux you get four files:
the zip, a portable `ModbusConnector.AppImage` (chmod +x and run — no
installation, any distro) and `modbus-connector_<version>_amd64.deb`
(`sudo dpkg -i …` installs to /opt with an app-menu entry on Debian/Ubuntu).

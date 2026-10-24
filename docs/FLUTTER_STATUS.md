# Flutter desktop migration status

Implemented on `feature/flutter-ui-migration`, 2026-10-24. The MVP is available
in `flutter_app/`; the existing PySide6 application is retained. Changes are
committed locally. Nothing was pushed and no PR was opened.

## Working MVP

- Material 3 system/light/dark UI with a minimal desktop layout and complete
  Windows/Linux runner projects, application title/icon, and minimum window size.
  At 900×650 logical pixels the compact controls leave usable table/chart/log
  panes; table and log have independent visible scrollbars. Validation banners
  and larger text can scroll the workspace instead of shrinking/clipping panes.
  Linux applies the minimum to the Flutter content, matching Windows client sizing.
- TCP host/port and serial RTU port discovery/manual entry, baud, parity, data
  bits, stop bits, unit and timeout. Enter connects; loading disables settings.
  Port refresh has its own progress state, clears old errors on success, offers
  selection/cancel/empty states, and focuses the selected serial port. Reconnect
  and range changes clear stale latency; bridge exit resets the connection label.
- Four register areas, 0-based start/count, decimal/hex values, validated single
  holding-register/coil write dialogs, and Escape to cancel. Pending range edits
  disable writes until a read applies the new range.
- Live polling from 100 ms, one transaction at a time, with no request backlog.
  Stop discards late results/errors; Disconnect gates controls immediately and
  waits for the active transaction. Failed reads stop polling; reconnect clears
  errors, and an exited bridge can be restarted by connecting again.
- A virtualized table (up to 125 registers / 2,000 bits), bounded activity log,
  and selected-row chart with timestamps, 300 samples and at most 10 Hz updates.
- Qt-free Python NDJSON subprocess bridge reusing `ModbusBackend` directly.
  Strict range/type validation precedes bus I/O. EOF/shutdown closes resources;
  app exit closes stdin with bounded cleanup and a process-termination fallback.
- Local demo using the existing `SimBackend` over actual loopback TCP, including
  writable holding/coils and animated input registers. No hardware is needed.
- Native PyInstaller bridge bundling helper for Windows and Linux. Release apps
  locate the adjacent bridge independently of working directory, without Python
  being installed on the destination machine.

## Validation completed on Linux

Environment: Flutter 3.47.8 stable / Dart 3.13.7; Python 3.13.5 for development and
Python 3.11.17 for the frozen bridge; x64 Linux with GTK 3 and Xvfb.

| Check | Result |
| --- | --- |
| `flutter analyze` | Clean; no suppressed Dart diagnostics |
| `flutter test` | 12 controller/widget tests passed |
| `flutter build linux --release` | Built `flutter_app/build/linux/x64/release/bundle/modbus_desktop` |
| `flutter test integration_test/desktop_test.dart -d linux` under Xvfb | Passed with the real bridge and TCP simulator |
| Native Linux release at 900×650 under Xvfb | Visually checked RTU form, demo connection, table/chart/log and polling |
| Python bridge + backend + serial regression tests | 80 passed |
| Ruff on all new Python files | Passed |
| Native bridge freeze using `tool/build_bridge.py` | Passed |
| Frozen bridge from `/tmp` | Handshake, serial discovery, TCP demo read/write and shutdown passed |
| Packaged release app from `/tmp`, without `MODBUS_PYTHON` | Opened, found its frozen bridge and connected to Local demo; visually inspected |

The desktop integration test runs at 900×650 with the real bridge and covers all
four areas, register/coil writes, animated 50-register polling at 100 ms, chart
selection/samples, pane bounds, Modbus exceptions, refused TCP connection,
disconnect/reconnect, unexpected bridge exit/restart, and shutdown. Widget tests
cover TCP validation/cancellation, RTU parameters and port-refresh recovery,
Enter/Escape, write validation, all four areas, polling controls, pending-range
write gating, table virtualization, and reaching the last of 2,000 rows at the
900×650 minimum. Layout tests also exercise validation/error states, independent
log scrolling, 150% display scale and larger text. Controller tests verify that
late transactions cannot revive a cancelled connection.

The Python 3.13 regression run emitted one asyncio transport-finalizer warning
from the existing TCP test fixture. Tests passed. This box's system Python lacks
its shared library, so standalone freezing used an isolated uv-managed Python
3.11 runtime. This does not affect source-mode operation.

## Run / build

See [flutter_app/README.md](../flutter_app/README.md) for complete Windows
PowerShell and Linux setup, development, testing and release-bundle commands.
See [BRIDGE_PROTOCOL.md](../flutter_app/BRIDGE_PROTOCOL.md) for the protocol and
cancellation behavior.

Linux development, from the repository root after installing the Python package:

```bash
export MODBUS_PYTHON="$PWD/.venv/bin/python"
cd flutter_app
flutter run -d linux
```

Windows requires Flutter, Python 3.11+ x64, and Visual Studio 2022 with Desktop
development with C++, CMake and the Windows SDK. Install this repository into a
Python venv, set `MODBUS_PYTHON` to its `Scripts\python.exe`, then run
`flutter run -d windows` from `flutter_app/`. For distribution, run
`flutter build windows --release`, then the documented `tool/build_bridge.py`
command on Windows, and ship the complete Release directory.

## Remaining validation and deferred scope

Windows compilation, packaged execution/high-DPI/close behavior and physical
serial hardware require a Windows/hardware pass; Linux cannot produce a Windows
binary. Both platform folders are complete generated native projects with the
small title/icon/minimum-size customizations. No Windows binary is claimed.
Linux packaging was tested on this box, without a broad distribution matrix or
formal frame-time benchmark. Physical RTU was not available; parameter forwarding
and existing backend serial behavior are covered by tests.

Deferred beyond MVP: multiple sessions, persistence/import/export, richer display
formats/scaling, scanner, sniffer/gateway/simulator management, templates, cloud
sync, alarms, localization, application updates, installers and code signing.
Flutter does not modify existing Qt settings. The original migration brief was
read and left unchanged, including its pre-existing untracked Git state.

## Parity push — chunk 1: sessions

- Added independent session tabs, each owning its controller and bridge process.
  Inactive sessions keep polling; tab controls/forms remain mounted when switching.
  Close waits for in-flight I/O and releases only that tab's process. Last-tab close
  creates a disconnected session. Window exit awaits all sessions.
- Linux verification: `flutter analyze` clean; `flutter test` 13 passed, including
  independent connections and closing a tab while another tab continues reading.
- Remaining: scanner; richer register tools; logger/alarms; mode panels; graph;
  templates/persistence; help/localization; cloud/update surfaces.

## Parity push — chunk 2: scanner

- Usable unit/address scanner dialog: editable/add/remove probes, range and area
  selection, progress/hits, Stop, device identification and apply unit/range.
- Reuses backend scan semantics, including two-register address probes and
  single-register fallback. Flutter sends individual probes to permit Stop
  between transactions; stopped results cannot appear late.
- Linux: `flutter analyze` clean, `flutter test` 14 passed; Python bridge 25 passed
  against a real TCP fixture, including invalid probes and absent addresses.
- Remaining: register tools; logger/alarms; mode panels; graph; templates/state;
  help/i18n; cloud/update. Scanner hit CSV/multiple disjoint-row insertion awaits
  the richer register map.

# Industrial workbench implementation

The approved homepage uses one device navigation sidebar, a compact connection
summary and acquisition toolbar, a dense register table, and a bottom activity
console. The top device tab strip must not duplicate the sidebar. Keep the
existing native Dart backend and all session ownership, polling, write,
selection, filtering, persistence and update-exit guarantees.

Implementation is split into independently validated commits, pushed after each
completed block as requested.

## Device navigation

- Replace the horizontal session chips with a single scrollable sidebar.
- Show session mode, connection state and a per-session close action; keep new
  session creation in the same navigation area.
- Use a drawer below 1100 logical pixels so existing minimum-width controls
  retain their space. Selecting a session closes the drawer.
- Preserve the keyed IndexedStack and TickerMode, so switching sessions keeps
  acquisition alive without animating hidden views. Existing shutdown paths
  continue to await owned resources.

Validation on this Mac: `flutter analyze` clean; all 121 Flutter tests pass.
After adding the minimum-window navigation assertions, all 7 workspace tests
pass again. The final `flutter drive --driver=test_driver/native_driver.dart
--target=integration_test/desktop_test.dart -d macos --profile` run builds and
passes, including real loopback TCP polling across sidebar switches, writes,
graphs and reconnect. The driver and test runner both report success (exit 0);
Flutter also emits its integration-test plugin detection warning at teardown.
No installed-app replacement or physical serial acceptance is claimed here.

## Industrial theme

`workbench_theme.dart` defines the shared light/dark palette used by the app,
graph windows and native appearance acceptance. It replaces tinted, rounded
Material cards with neutral surfaces, fine separators and 4 px panel corners;
controls use 3 px corners, compact padding and smaller type. Input focus and
disabled states remain distinct. Layout dimensions remain minimums so text
scaling can grow controls; saved table density is not changed.

The native appearance test uses the real isolate/loopback simulator and captures
light, dark and 900×650 Chinese text at 130% scale into `build/ui_acceptance/`.
It also writes an engineering value while polling, verifies the raw register
readback and checks that changing the theme does not disconnect acquisition.
Capture disables the theme transition to inspect stable colors; the explicit
MediaQuery size matches the native test surface size.

Validation: analyzer clean; all 121 Flutter tests pass. The final native
`appearance_test.dart` Profile run passes all three display scenes and confirms
23.5 °C writes read back as raw 235 while polling remains active. The generated
PNGs were inspected: both palettes are readable and minimum-size Chinese
controls fit without overlap. The virtualized table remains scrollable when
large text reduces the number of visible rows. As with the desktop run, the
driver reports success with the integration-test plugin warning at teardown.

## Register work area and bottom console

- Connection settings and connection actions sit beside the endpoint summary.
- Activity now docks below the full-width map, with filtering, log export,
  diagnostics and a collapse control. Short windows initially fold the console.
- The status strip uses actual connection/polling state, unit, TX/RX bytes,
  errors and average operation latency. Horizontal overflow cannot change its
  height as counters grow.
- Default columns group address, name, format, engineering value and raw HEX;
  smaller widths, tabular numbers, alternate rows and fine grid lines make the
  map denser. Row height stays 48 px; saved columns remain authoritative.
- Writable engineering-value cells open the existing validated write dialog,
  including during polling. Row menus, inline enums and read-only restrictions
  remain available. New demos use the default map layout and explicitly enable
  the two signal trends; existing saved demo layouts are not rewritten.
- Filter counts reserve a stable width so changing row counts does not resize
  the table. Selection controls still float above the unchanged viewport.

Validation: analyzer clean; the 121-test full regression passes, followed by
the new engineering-value hit-target test. The final native appearance run
passes light/dark/minimum-size scenes and actual dialog writes of 23.5, 24.5
and 25.5, with raw readback verified while polling continues. Native assertions
also check console collapse and unchanged table bounds during selection. The
three final PNGs were inspected for grid lines, contrast and control fit.

## Resize performance and final acceptance

The first final performance run exposed repeated construction of visible table
cells during viewport changes: resize p90 build time was 31.041 ms against the
existing 16.7 ms limit. No threshold was changed. Workbench now retains its
session-bound register panel, which owns its own data listeners. RegisterMapPanel
builds toolbar/table widgets outside the viewport constraint callback, and
DesktopTable likewise keeps its header and lazy body outside that callback.
The connection summary, map card and activity console are also built outside
the constraint callback, and the table preloads one row beyond the viewport
instead of a large buffer of interactive cells.
Resizing lays out these widgets while model, theme, language and selection
updates still rebuild their contents. Column resizing and visibility changes
remain managed by DesktopTable state.

After this change, `flutter analyze` reports no issues and all 122 Flutter tests
pass. The desktop, parity and isolated template native runs passed before this
performance-only refactor; the template fixture contains 6 and 150 rows and does
not represent an online manufacturer catalog.

The performance harness now uses the production theme, records all phases
before checking the unchanged 16.7 ms build-time budgets, and snapshots the
acquisition notification count before later interactions. Its history phase
explicitly enables trends and asserts 248 series with 1000 samples each; the old
fixture omitted `trend_enabled`, leaving those series empty. Intermediate runs
and their failures are retained in the local evidence directory.

The final standalone Profile stress run uses the same prebuilt native app with
248 rows and the asserted history population. It does **not** meet the existing
16.7 ms p90 frame-build budget: acquisition 38.813 ms, history scrolling
19.983 ms, and resizing 54.882 ms. A preceding run without populated histories
measured scrolling 6.794 ms and resizing 11.479 ms, but that is not evidence for
the full-history workload. Functional correctness and a guaranteed 60 Hz stress
budget are distinct; no performance pass is claimed. The older acceptance
report already recorded a resize budget failure, and this corrected fixture
adds a materially heavier history workload.

Final functional recheck after the resize/buffer changes: analyzer clean;
18 workbench/table cases pass, followed by all 9 table cases after the final
one-row buffer adjustment. The native appearance test passes again, including
live value readback in all three themes/window scenes and console/selection
viewport assertions. There are no suppressed performance assertions.

## Cross-platform CI navigation

Windows native CI exposed a test assumption: its host window can remain narrow
even after `setSurfaceSize(1280, 800)`, so session navigation lives in the drawer.
The native test now opens the Sessions drawer when the sidebar item is absent,
then selects it and verifies acquisition continues. It retains the same wide
sidebar assertions on hosts where the sidebar is visible.

## Release build and evidence

The final macOS desktop native run also passes after all layout changes and the
drawer-aware test fix. The five native files were run separately: appearance,
desktop, parity and templates pass; performance retains the explicitly recorded
budget failure above. Profile runs report success/failure through both the driver
and exit status, despite Flutter's plugin-detection warning at teardown.

`bash tool/package_macos.sh` built version 0.16.12 (build 12), verified all five
Mach-O files contain arm64/x86_64, verified the deep strict code signature, and
created `modbus-connector-flutter-0.16.12-macos-universal.dmg` (23,445,257 bytes).
The generated SHA-256 matches the DMG:
`dcffadc6e72c85f1c33e8e8517b48498eaed4e904741100c7cd643c90d2afd11`.
The application identifier remains `com.modbusconnector.modbusDesktop`.

Native screenshots and full logs, including failed stress measurements, are
archived at `/Users/dyh/.local/share/modbus-ui-redesign-acceptance/evidence/`.
The Release process starts with a separate `MODBUS_FLUTTER_HOME`; the installed
application and its workspace are not replaced. A manual Release-window
inspection could not proceed because macOS was locked. The light/dark/minimum
visual checks and actual UI writes above come from the real native Profile app.
No Apple Silicon hardware, physical serial or new Windows physical-device
acceptance is claimed. CI includes Windows/Linux native loopback tests and
Windows installer validation; the macOS GUI artifact is built locally.

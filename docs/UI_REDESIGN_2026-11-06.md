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

## Remaining acceptance

Run the full Flutter checks and native integration files separately, inspect
   the resulting macOS application in light/dark modes and at minimum size,
   and record evidence. Build the universal macOS bundle with the repository
   script. This verifies this Mac and local TCP simulation; it does not establish
   Windows installation or physical serial acceptance.

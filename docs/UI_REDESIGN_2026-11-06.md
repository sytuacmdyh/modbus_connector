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

## Remaining implementation blocks

1. Apply the restrained light/dark industrial theme: compact controls, small
   radii, neutral surfaces, fine separators and clear numeric typography.
2. Reorganize the master connection summary, map toolbar and filters; improve
   table density and column presentation while retaining saved overrides and
   the required 48 px default and hidden Area/Count/Unit defaults.
3. Move activity into a collapsible bottom console and add a compact status
   strip backed by real session state. Keep logging, export and diagnostics
   accessible and preserve the table viewport during row selection.
4. Run the full Flutter checks and native integration files separately, inspect
   the resulting macOS application in light/dark modes and at minimum size,
   and record evidence. Build the universal macOS bundle with the repository
   script. This verifies this Mac and local TCP simulation; it does not establish
   Windows installation or physical serial acceptance.

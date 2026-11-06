import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:modbus_desktop/src/desktop_table.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/workspace.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/workbench_theme.dart';

// A small real-device response delay prevents instant local replies from hiding
// per-request rebuilds between frames. All service I/O uses the real native backend.
class PacedBridge extends NativeBridge {
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    final reply = await super.request(command, timeout: timeout);
    if (command['command'] == 'read_rows') {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    return reply;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('large map remains responsive during independent reads', (
    tester,
  ) async {
    await binding.setSurfaceSize(const Size(1280, 800));
    final workspace = WorkspaceController(bridgeFactory: PacedBridge.new);
    final session = workspace.sessions.first;
    session.registers.addAll(
      List.generate(
        248,
        (i) => <String, dynamic>{
          'name': 'Register $i',
          'kind': 'holding_registers',
          'address': i,
          'count': 1,
          'format': 'dec',
          'poll_enabled': true,
        },
      ),
    );
    try {
      await session.connect({'transport': 'demo', 'timeout': 1.0}, 1);
      await tester.pumpWidget(
        MaterialApp(
          theme: workbenchTheme(Brightness.light),
          home: SessionWorkspace(
            controller: workspace,
            themeMode: ThemeMode.light,
            onThemeChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Warm font/shader caches before measuring the repeated interaction.
      await session.registerMap.read();
      await tester.pumpAndSettle();
      var notifications = 0;
      session.addListener(() => notifications++);
      await binding.watchPerformance(() async {
        for (var cycle = 0; cycle < 3; cycle++) {
          final reading = session.registerMap.read();
          final table = find.byType(DesktopTable);
          await tester.drag(table, const Offset(0, -180));
          await reading;
          await tester.pumpAndSettle();
          await tester.drag(table, const Offset(0, 180));
          await tester.pumpAndSettle();
        }
      }, reportKey: 'large_map');
      final acquisitionNotifications = notifications;
      debugPrint(
        'PERFORMANCE ${binding.reportData} notifications=$notifications',
      );
      expect(session.registerResults, hasLength(248));
      expect(session.error, isNull);
      final checks = find.descendant(
        of: find.byType(DesktopTable),
        matching: find.byType(Checkbox),
      );
      final selection = await tester.startGesture(
        tester.getCenter(checks.first),
        kind: PointerDeviceKind.mouse,
      );
      await selection.moveTo(tester.getCenter(checks.at(2)));
      await selection.up();
      // Retire the synthetic mouse before later touch-driven button interactions.
      await selection.removePointer();
      await tester.pumpAndSettle();
      expect(
        tester.widgetList<Checkbox>(checks).where((c) => c.value == true),
        hasLength(3),
      );
      expect(session.registers.every((r) => r['poll_enabled'] == true), isTrue);
      await tester.tap(find.byKey(const ValueKey('disable-selected-polling')));
      await tester.pumpAndSettle();
      expect(
        session.registers.where((r) => r['poll_enabled'] == false),
        hasLength(3),
      );
      expect(find.byIcon(Icons.pause_circle_outline), findsNWidgets(3));
      await tester.tap(find.byKey(const ValueKey('enable-selected-polling')));
      await tester.pumpAndSettle();
      expect(session.registers.every((r) => r['poll_enabled'] == true), isTrue);
      session.registerMap.setRuntimeFlags(
        List.generate(session.registers.length, (i) => i),
        trendEnabled: true,
      );
      await session.registerMap.read();
      await tester.pumpAndSettle();
      // Scrolling after a long acquisition must stay cheap with full histories.
      expect(session.histories, hasLength(248));
      final now = DateTime.now();
      for (final points in session.histories.values) {
        points.clear();
        points.addAll(
          List.generate(
            1000,
            (i) => Sample(
              now.subtract(Duration(milliseconds: (1000 - i) * 100)),
              (i % 100).toDouble(),
            ),
          ),
        );
      }
      expect(
        session.histories.values.every((points) => points.length == 1000),
        isTrue,
      );
      await session.disconnect();
      await tester.pumpAndSettle();
      await binding.watchPerformance(() async {
        for (var i = 0; i < 8; i++) {
          await tester.fling(
            find.byType(DesktopTable),
            Offset(0, i.isEven ? -700 : 700),
            1800,
          );
          await tester.pumpAndSettle();
        }
      }, reportKey: 'scroll_full_history');
      await binding.watchPerformance(() async {
        for (var i = 0; i < 20; i++) {
          await binding.setSurfaceSize(Size(1000 + (i % 5) * 60, 760));
          await tester.pump();
        }
        await binding.setSurfaceSize(const Size(1280, 800));
        await tester.pumpAndSettle();
      }, reportKey: 'resize_full_history');
      for (final key in ['scroll_full_history', 'resize_full_history']) {
        final report = binding.reportData![key] as Map;
        debugPrint(
          'INTERACTION $key ${Map.of(report)
            ..remove('frame_build_times')
            ..remove('frame_rasterizer_times')}',
        );
      }
      // Collect every phase before asserting, so a failed acquisition budget
      // does not hide scroll/resize measurements from the same run.
      if (!const bool.fromEnvironment('PERFORMANCE_BASELINE')) {
        expect(acquisitionNotifications, lessThanOrEqualTo(18));
      }
      for (final key in [
        if (!const bool.fromEnvironment('PERFORMANCE_BASELINE')) 'large_map',
        'scroll_full_history',
        'resize_full_history',
      ]) {
        final report = binding.reportData![key] as Map;
        expect(
          report['90th_percentile_frame_build_time_millis'],
          lessThan(16.7),
          reason: key,
        );
      }
    } finally {
      await workspace.shutdown();
      workspace.dispose();
      await tester.pumpWidget(const SizedBox());
    }
  });
}

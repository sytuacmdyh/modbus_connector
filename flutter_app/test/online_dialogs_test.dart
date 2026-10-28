import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/online_dialogs.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

class OnlineBridge extends FakeBridge {
  bool cancelled = false;
  bool running = true;
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> c, {
    Duration? timeout,
  }) async {
    calls.add(c);
    switch (c['command']) {
      case 'cloud_settings_load':
        return const BridgeReply({
          'settings': {
            'url': 'https://example.invalid',
            'username': 'alice',
            'password': '',
            'templates_path': 'templates',
            'timeout': 15,
            'mode': 'consumer',
            'remember_password': false,
          },
        }, false);
      case 'cloud_start':
        running = true;
        return const BridgeReply({'started': true}, false);
      case 'cloud_cancel':
        cancelled = true;
        running = false;
        return const BridgeReply({}, false);
      case 'cloud_status':
        return BridgeReply({
          'running': running,
          'result': null,
          'error': cancelled ? 'cancelled' : null,
        }, false);
      case 'update_check':
        return const BridgeReply({
          'current': '1.0.0',
          'release': {'tag': 'v2.0.0', 'notes': 'Plain release notes'},
          'newer': true,
          'install_supported': false,
          'install_reason': 'Manual installation required',
          'url': 'https://github.com/sytuacmdyh/modbus_connector/releases',
        }, false);
    }
    return super.request(c, timeout: timeout);
  }
}

void main() {
  testWidgets(
    'consumer hides publishing and cancelling waits for task boundary',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = OnlineBridge();
      final session = SessionController(bridge);
      await tester.pumpWidget(MaterialApp(home: CloudDialog(session: session)));
      await tester.pumpAndSettle();
      expect(find.text('Publish templates'), findsNothing);
      expect(find.text('Activate version'), findsNothing);
      await tester.tap(find.text('Download current templates'));
      await tester.pump();
      expect(find.text('Cancel transfer'), findsOneWidget);
      await tester.tap(find.text('Cancel transfer'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(bridge.cancelled, isTrue);
      expect(find.text('cancelled'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets('update dialog shows plain notes and manual-install limitation', (
    tester,
  ) async {
    final session = SessionController(OnlineBridge());
    await tester.pumpWidget(MaterialApp(home: UpdateDialog(session: session)));
    await tester.tap(find.text('Check now'));
    await tester.pumpAndSettle();
    expect(find.text('Plain release notes'), findsOneWidget);
    expect(find.text('Manual installation required'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
}

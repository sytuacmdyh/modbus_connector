import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/device_panel.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

class DeviceBridge extends FakeBridge {
  bool running = false;
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    switch (command['command']) {
      case 'device_start':
        calls.add(command);
        running = true;
        return const BridgeReply({'running': true}, false);
      case 'device_stop':
        calls.add(command);
        running = false;
        return const BridgeReply({'running': false}, false);
      case 'sim_configure':
        calls.add(command);
        return const BridgeReply({}, false);
      case 'device_status':
        return BridgeReply({
          'simulator': running,
          'sniffer': running,
          'gateway': running,
          'rows': [],
          'events': [],
          'dropped': 0,
          'units': [],
        }, false);
    }
    return super.request(command, timeout: timeout);
  }
}

void main() {
  testWidgets(
    'simulator form starts/stops and mode panels fit minimum desktop',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = DeviceBridge();
      final session = SessionController(bridge)..mode = 'simulator';
      await tester.pumpWidget(MaterialApp(home: DevicePanel(session: session)));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(session.deviceRunning, isTrue);
      expect(bridge.calls.last['command'], 'device_start');
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(bridge.running, isFalse);
      for (final mode in ['sniffer', 'gateway']) {
        session.mode = mode;
        await tester.pumpWidget(
          MaterialApp(
            home: DevicePanel(key: ValueKey(mode), session: session),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}

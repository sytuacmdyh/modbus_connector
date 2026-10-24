import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/register_map.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

class MapBridge extends FakeBridge {
  Completer<BridgeReply>? held;
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    if (command['command'] == 'read_rows') {
      calls.add(command);
      return held?.future ??
          Future.value(
            BridgeReply({
              'rows': [
                {
                  'values': [value],
                  'display': '$value',
                  'numeric': value,
                  'alarm': null,
                },
              ],
            }, true),
          );
    }
    return super.request(command, timeout: timeout);
  }
}

void main() {
  test(
    'map cancellation suppresses stale data and raw snapshots detect changes',
    () async {
      final bridge = MapBridge();
      final session = SessionController(bridge);
      session.registers.add({'name': 'X', 'address': 0});
      await session.connect({'timeout': 0.1}, 1);
      final model = RegisterMapController(session);
      await model.read();
      model.capture('before');
      expect(model.diff('before'), isEmpty);
      bridge.value = 42;
      await model.read();
      expect(model.diff('before').single, contains('100'));
      bridge.held = Completer<BridgeReply>();
      final reading = model.read();
      model.stop();
      bridge.held!.complete(
        const BridgeReply({
          'rows': [
            {
              'values': [99],
            },
          ],
        }, true),
      );
      await reading;
      expect(model.results.single['values'], [42]);
      model.dispose();
      session.dispose();
    },
  );
  test('stopped map discards late alarm/error side effects and removed snapshots stay visible', () async {
    final bridge = MapBridge();
    final session = SessionController(bridge);
    session.registers.add({
      'name': 'X',
      'kind': 'holding_registers',
      'address': 0,
      'count': 1,
    });
    await session.connect({'timeout': 0.1}, 1);
    final model = RegisterMapController(session);
    await model.read();
    model.capture('old');
    bridge.held = Completer<BridgeReply>();
    final reading = model.read();
    model.stop();
    bridge.held!.completeError(const BridgeException('late error'));
    await reading;
    expect(session.error, isNull);
    expect(
      session.logs.where((l) => l.message.contains('late error')),
      isEmpty,
    );
    session.registers.clear();
    expect(model.diff('old').single, contains('(removed)'));
    model.dispose();
    session.dispose();
  });
  test(
    'map scheduler skips disabled rows and honors per-row intervals',
    () async {
      var now = DateTime(2026);
      final bridge = MapBridge();
      final session = SessionController(bridge);
      await session.connect({'timeout': 0.1}, 1);
      session.registers.addAll([
        {
          'name': 'fast',
          'kind': 'holding_registers',
          'address': 0,
          'count': 1,
          'poll_ms': 100,
        },
        {
          'name': 'slow',
          'kind': 'holding_registers',
          'address': 1,
          'count': 1,
          'poll_ms': 1000,
        },
        {
          'name': 'disabled',
          'kind': 'holding_registers',
          'address': 2,
          'count': 1,
          'poll_enabled': false,
        },
      ]);
      final model = RegisterMapController(session, clock: () => now);
      await model.read(dueOnly: true);
      expect(bridge.calls.where((c) => c['command'] == 'read_rows').length, 2);
      now = now.add(const Duration(milliseconds: 200));
      await model.read(dueOnly: true);
      expect(bridge.calls.where((c) => c['command'] == 'read_rows').length, 3);
      now = now.add(const Duration(milliseconds: 800));
      await model.read(dueOnly: true);
      expect(bridge.calls.where((c) => c['command'] == 'read_rows').length, 5);
      expect(session.registerResults.last['values'], isNull);
      model.dispose();
      session.dispose();
    },
  );
  testWidgets(
    'row editor validates width and bits editor toggles all 16 bits',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: RegisterRowDialog()));
      await tester.enterText(
        find.widgetWithText(TextField, 'address'),
        '65536',
      );
      await tester.tap(find.text('Apply'));
      await tester.pump();
      expect(find.textContaining('Check address/count'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const BitsDialog(value: 0),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('b0 '));
      await tester.pump();
      expect(find.text('Bits · 0x0001'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

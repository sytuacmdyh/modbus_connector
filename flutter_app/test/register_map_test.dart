import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class ExpressionMapBridge extends MapBridge {
  final evaluation = Completer<BridgeReply>();
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) {
    if (command['command'] == 'evaluate_expressions') return evaluation.future;
    return super.request(command, timeout: timeout);
  }
}

void main() {
  test('stopping map suppresses late expression evaluation failures', () async {
    final bridge = ExpressionMapBridge();
    final session = SessionController(bridge);
    await session.connect({'timeout': 0.1}, 1);
    session.registers.add({'name': 'x', 'address': 0});
    session.expressions.add({'name': 'fx', 'text': '[x]*2'});
    final reading = session.registerMap.read();
    await Future<void>.delayed(Duration.zero);
    session.registerMap.stop();
    bridge.evaluation.completeError(
      const BridgeException('late expression error'),
    );
    await reading;
    expect(session.error, isNull);
    expect(session.expressionResults, isEmpty);
    expect(
      session.logs.where((l) => l.message.contains('late expression error')),
      isEmpty,
    );
    session.dispose();
  });

  testWidgets(
    'inline enum writes raw values without applying engineering scale',
    (tester) async {
      final bridge = MapBridge();
      final session = SessionController(bridge);
      await session.connect({'timeout': 0.1}, 1);
      session.registers.add({
        'name': 'State',
        'kind': 'holding_registers',
        'address': 0,
        'count': 1,
        'format': 'dec',
        'scale': 10,
        'value_names': {'0': 'Off', '1': 'On'},
      });
      await tester.pumpWidget(
        MaterialApp(home: RegisterMapDialog(session: session)),
      );
      await tester.ensureVisible(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 = On').last);
      await tester.pumpAndSettle();
      expect(
        bridge.calls.firstWhere((c) => c['command'] == 'write')['values'],
        [1],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('map shortcuts select duplicate move and delete rows', (
    tester,
  ) async {
    final session = SessionController(MapBridge());
    session.registers.addAll([
      for (var i = 0; i < 2; i++)
        {
          'name': 'row$i',
          'kind': 'holding_registers',
          'address': i,
          'count': 1,
          'format': 'dec',
        },
    ]);
    await tester.pumpWidget(
      MaterialApp(home: RegisterMapDialog(session: session)),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.tap(find.byTooltip('Selected rows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate selected rows'));
    await tester.pumpAndSettle();
    expect(session.registers.length, 4);
    expect(session.registers.last['name'], 'row1 copy');
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(session.registers.map((r) => r['name']), ['row0 copy', 'row1 copy']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets(
    'session map keeps polling after dialog closes, stops on disconnect',
    (tester) async {
      final bridge = MapBridge();
      final session = SessionController(
        bridge,
        clock: () => tester.binding.clock.now(),
      );
      session.registers.add({
        'name': 'X',
        'kind': 'holding_registers',
        'address': 0,
        'count': 1,
        'format': 'dec',
      });
      await session.connect({'timeout': 0.1}, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => RegisterMapDialog(session: session),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Poll map'));
      await tester.pump();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      final count = bridge.calls.length;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(session.registerMap.polling, isTrue);
      expect(bridge.calls.length, greaterThan(count));
      await session.disconnect();
      expect(session.registerMap.polling, isFalse);
      final stopped = bridge.calls.length;
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.calls.length, stopped);
      session.dispose();
    },
  );

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

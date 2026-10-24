import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:modbus_desktop/main.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/session_controller.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'desktop → stdio Python → real simulator: read, write, poll, reconnect',
    (tester) async {
      await binding.setSurfaceSize(const Size(900, 650));
      addTearDown(() => binding.setSurfaceSize(null));
      final session = SessionController(ProcessBridge());
      await tester.pumpWidget(ModbusApp(controller: session));
      // Drive the visible connect controls, then exercise the same controller used
      // by the table. No mock transport or replacement Modbus implementation.
      await tester.tap(find.text('Serial RTU'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local demo').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      for (
        var i = 0;
        i < 150 && !session.connected && session.error == null;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(session.error, isNull);
      expect(session.connected, isTrue);
      await session.read();
      expect(session.values.take(3), [100, 101, 102]);
      await session.write(0, 32123);
      expect(session.values.first, 32123);
      session.setQuery(const ReadQuery(kind: 'coils', count: 50));
      await session.read();
      expect(session.values.take(2), [true, false]);
      await session.write(1, 1);
      expect(session.values[1], true);
      session.setQuery(const ReadQuery(kind: 'discrete_inputs', count: 50));
      await session.read();
      expect(session.values.take(4), [true, false, false, true]);
      session.setQuery(const ReadQuery(kind: 'input_registers', count: 50));
      session.intervalMs = 100;
      session.startPolling();
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      session.stopPolling();
      while (session.busy) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(session.samples.length, greaterThan(3));
      expect(
        session.samples.map((s) => s.value).toSet().length,
        greaterThan(1),
      );
      await tester.pumpAndSettle();
      expect(find.text('Live trend · @0'), findsOneWidget);
      final table = find.byKey(const ValueKey('register-list'));
      expect(tester.getRect(table).bottom, lessThanOrEqualTo(650));
      expect(
        tester.getRect(find.widgetWithText(Card, 'Activity')).bottom,
        lessThanOrEqualTo(650),
      );
      await tester.tap(find.text('2').first);
      await tester.pumpAndSettle();
      expect(session.selected, 2);
      expect(find.text('Live trend · @2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await session.disconnect();
      expect(session.connected, isFalse);
      await session.connect({'transport': 'demo', 'timeout': 0.2}, 1);
      session.setQuery(const ReadQuery(address: 10000, count: 1));
      await session.read();
      expect(session.error, contains('Illegal Data Address'));
      session.setQuery(const ReadQuery());
      await session.read();
      expect(session.error, isNull);
      expect(session.values.first, 100);
      await session.disconnect();
      await session.connect({
        'transport': 'tcp',
        'host': '127.0.0.1',
        'port': 1,
        'timeout': 0.1,
      }, 1);
      expect(session.connected, isFalse);
      expect(session.error, isNotNull);
      await session.connect({'transport': 'demo', 'timeout': 0.2}, 1);
      expect(session.error, isNull);
      // An unexpected bridge exit must drop the connection and allow a fresh child.
      await session.bridge.request({'command': 'shutdown'});
      for (var i = 0; i < 50 && session.connected; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(session.connected, isFalse);
      await session.connect({'transport': 'demo', 'timeout': 0.2}, 1);
      expect(session.connected, isTrue);
      expect(session.error, isNull);
      await session.shutdown();
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}

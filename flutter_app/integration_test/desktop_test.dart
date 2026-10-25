import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:modbus_desktop/main.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/register_map.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'desktop → stdio Python → real simulator: read, write, poll, reconnect',
    (tester) async {
      await binding.setSurfaceSize(const Size(900, 650));
      addTearDown(() => binding.setSurfaceSize(null));
      final session = SessionController(ProcessBridge());
      session.draft['map_table'] = {
        'order': ['actions', 'name', 'value'],
      };
      await tester.pumpWidget(ModbusApp(controller: session));
      // Drive the visible connect controls, then exercise the same controller used
      // by the register map. No mock transport or replacement Modbus implementation.
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
      expect(find.text('Read'), findsNothing);
      expect(find.text('Start polling'), findsNothing);
      await tester.tap(find.text('Add row'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Manual register',
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(session.registers.single['address'], 0);
      await tester.tap(find.text('Read map'));
      for (var i = 0; i < 100 && session.registerResults.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(session.error, isNull);
      expect(session.registerResults.single['values'], [100]);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Write row'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '32123',
      );
      await tester.tap(find.text('Apply'));
      for (
        var i = 0;
        i < 100 && session.registerResults.single['display'] != '32123';
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(session.error, isNull);
      expect(session.registerResults.single['values'], [32123]);
      await tester.tap(find.text('Poll map'));
      for (var i = 0; i < 18; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(session.registerMap.polling, isTrue);
      expect(
        session.histories.values.any((points) => points.length > 2),
        isTrue,
      );
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(session.registerMap.polling, isFalse);
      expect(find.byType(RegisterMapPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Preserve backend coverage for all four Modbus areas and reconnects.
      await session.read();
      expect(session.values.take(3), [32123, 101, 102]);
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

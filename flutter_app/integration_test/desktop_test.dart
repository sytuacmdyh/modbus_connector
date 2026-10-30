import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:modbus_desktop/src/graph_dialog.dart';
import 'package:modbus_desktop/src/register_map.dart';
import 'package:modbus_desktop/src/workspace.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'local demo opens isolated map, animates, writes, graphs and reconnects',
    (tester) async {
      // Profile desktop runs use the native IME unless the test keyboard is registered.
      binding.testTextInput.register();
      await binding.setSurfaceSize(const Size(1280, 800));
      final workspace = WorkspaceController();
      final device = workspace.sessions.first;
      device.registers.add({
        'name': 'Real device',
        'kind': 'holding_registers',
        'address': 600,
        'count': 1,
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SessionWorkspace(
              controller: workspace,
              themeMode: ThemeMode.system,
              onThemeChanged: (_) {},
            ),
          ),
        );
        await tester.tap(find.byTooltip('Workspace'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text('Local demo'));
        for (
          var i = 0;
          i < 150 &&
              (workspace.sessions.length < 2 ||
                  workspace.sessions.last.registerResults.length < 6);
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(workspace.sessions, hasLength(2));
        expect(device.registers.single['address'], 600);
        expect(device.connected, isFalse);
        final demo = workspace.sessions.last;
        expect(
          demo.connected,
          isTrue,
          reason: 'busy=${demo.busy}; error=${demo.error}; logs=${demo.logs}',
        );
        expect(demo.registerMap.polling, isTrue);
        expect(demo.error, isNull);
        expect(demo.registers, hasLength(6));
        expect(
          demo.registerResults[0]['values'].single,
          inInclusiveRange(500, 1500),
        );
        expect(demo.registerResults[2]['values'], [100]);
        expect(demo.registerResults[4]['values'], [true]);
        expect(demo.registerResults[5]['values'], [true]);
        for (final row in demo.registers) {
          row['trend_enabled'] = true;
        }
        final first = demo.registerResults[0]['values'].single;
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(demo.registerResults[0]['values'].single, isNot(first));
        expect(demo.histories.values.first.length, greaterThan(2));
        expect(find.text('Read'), findsNothing);
        expect(find.byType(RegisterMapPanel), findsOneWidget);
        await tester.tap(find.text('Stop'));
        expect(demo.registerMap.polling, isFalse);
        for (
          var i = 0;
          i < 500 && (demo.busy || demo.registerMap.reading);
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(demo.busy, isFalse, reason: demo.error);
        expect(demo.registerMap.reading, isFalse);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byTooltip('Write row').at(2));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '23.5',
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester
              .widget<TextField>(
                find.descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(TextField),
                ),
              )
              .controller!
              .text,
          '23.5',
        );
        await tester.tap(find.text('Apply'));
        for (
          var i = 0;
          i < 100 && demo.registerResults[2]['values'].single != 235;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(demo.error, isNull, reason: '${demo.registers[2]}');
        expect(demo.registerResults[2]['values'], [235]);
        await demo.registerMap.quickValue(4, 'zero');
        expect(demo.registerResults[4]['values'], [false]);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text('More tools'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byTooltip('Graph map'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(GraphDialog), findsOneWidget);
        expect(find.text('Demo signal A @0'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.ensureVisible(find.text('Disconnect'));
        await tester.tap(find.text('Disconnect'));
        for (var i = 0; i < 100 && demo.disconnecting; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(demo.connected, isFalse);
        expect(demo.registerMap.polling, isFalse);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.text('Connect'));
        for (var i = 0; i < 100 && !demo.connected; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await demo.registerMap.read();
        expect(demo.registerResults[2]['values'], [100]);
        expect(demo.registerResults[4]['values'], [true]);
        expect(demo.error, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await workspace.shutdown().timeout(const Duration(seconds: 10));
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        await binding.setSurfaceSize(null);
        binding.testTextInput.unregister();
      }
    },
  );
}

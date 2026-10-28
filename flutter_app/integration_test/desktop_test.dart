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
        await tester.pumpAndSettle();
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
        expect(demo.connected, isTrue);
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
        final first = demo.registerResults[0]['values'].single;
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(demo.registerResults[0]['values'].single, isNot(first));
        expect(demo.histories.values.first.length, greaterThan(2));
        expect(find.text('Read'), findsNothing);
        expect(find.byType(RegisterMapPanel), findsOneWidget);
        await tester.tap(find.text('Stop'));
        while (demo.busy || demo.registerMap.reading) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Write row').at(2));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
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
        expect(demo.error, isNull);
        expect(demo.registerResults[2]['values'], [235]);
        await demo.registerMap.quickValue(4, 'zero');
        expect(demo.registerResults[4]['values'], [false]);
        await tester.pumpAndSettle();
        await tester.tap(find.text('More tools'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Graph map'));
        await tester.pumpAndSettle();
        expect(find.byType(GraphDialog), findsOneWidget);
        expect(find.text('Demo signal A @0'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Disconnect'));
        await tester.tap(find.text('Disconnect'));
        for (var i = 0; i < 100 && demo.disconnecting; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(demo.connected, isFalse);
        expect(demo.registerMap.polling, isFalse);
        await tester.pumpAndSettle();
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
        await workspace.shutdown();
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        await binding.setSurfaceSize(null);
      }
    },
  );
}

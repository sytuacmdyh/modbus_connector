import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:modbus_desktop/src/settings_store.dart';
import 'package:modbus_desktop/src/workspace.dart';
import 'package:modbus_desktop/src/workbench.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'independent native tabs: simulator rules, master map/logger/templates/state',
    (tester) async {
      await binding.setSurfaceSize(const Size(900, 650));
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      final temporary = await Directory.systemTemp.createTemp('modbus-parity');
      final workspace = WorkspaceController();
      final sim = workspace.sessions.first;
      sim.mode = 'simulator';
      sim.deviceConfig['listen'] = {
        'transport': 'tcp',
        'host': '127.0.0.1',
        'port': port,
        'timeout': 0.2,
      };
      sim.simRows.add({
        'name': 'Counter',
        'kind': 'holding_registers',
        'address': 0,
        'count': 1,
        'format': 'dec',
        'values': [7],
        'rule_text': 'prev+1',
      });
      sim.deviceConfig['tick_ms'] = 100;
      workspace.add();
      final master = workspace.sessions.last;
      workspace.select(0);
      await tester.pumpWidget(
        MaterialApp(
          home: SessionWorkspace(
            controller: workspace,
            themeMode: ThemeMode.system,
            onThemeChanged: (_) {},
          ),
        ),
      );
      expect(find.byTooltip('Session mode'), findsOneWidget);
      await tester.tap(find.text('Start'));
      for (var i = 0; i < 100 && !sim.deviceRunning && sim.error == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(sim.error, isNull);
      expect(sim.deviceRunning, isTrue);
      workspace.select(1);
      await tester.pumpAndSettle();
      await master.connect({
        'transport': 'tcp',
        'host': '127.0.0.1',
        'port': port,
        'timeout': 0.2,
      }, 1);

      master.registers.add({
        'name': 'Counter',
        'kind': 'holding_registers',
        'address': 0,
        'count': 1,
        'format': 'dec',
        'scale': 2,
        'offset': 0,
        'unit': 'rpm',
      });
      master.registers.add({
        'name': 'Adjacent',
        'address': 1,
        'kind': 'holding_registers',
        'count': 1,
        'format': 'dec',
      });
      master.expressions.add({'name': 'Double counter', 'text': '[Counter]*2'});
      master.mapGrouped = true;
      final map = master.registerMap;
      await map.read();
      expect(master.registerResults, hasLength(2));
      expect(
        master.expressionResults.single['numeric'],
        (master.registerResults.first['numeric'] as num) * 2,
      );
      map.capture('before');
      await tester.pump(const Duration(milliseconds: 350));
      await map.read();
      expect(map.diff('before'), isNotEmpty);
      expect(master.histories, isNotEmpty);
      await master.startLogging(
        {
          'path': '${temporary.path}/log.csv',
          'format': 'csv',
          'append': true,
          'interval_ms': 100,
        },
        master.registers,
        expressionRows: master.expressions,
      );
      for (var i = 0; i < 50 && master.loggedSamples == 0; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await master.stopLogging();
      expect(
        await File('${temporary.path}/log.csv').readAsString(),
        contains('fx Double counter'),
      );
      final catalog = await master.command({'command': 'template_list'});
      expect(catalog!['public'], isNotEmpty);
      final encoded = await master.command({
        'command': 'csv_export',
        'rows': master.registers,
      });
      expect(encoded!['text'], contains('Counter'));
      final store = SettingsStore(
        directory: Directory('${temporary.path}/state'),
      );
      await store.save(workspace.exportState());
      expect((await store.load())!['tabs'], hasLength(2));
      await tester.tap(find.byTooltip('Register map / CSV / snapshots'));
      await tester.pumpAndSettle();
      expect(find.text('Register map'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Poll map'));
      await tester.pump(const Duration(milliseconds: 200));
      // Scroll the page itself; a drag over the map scrolls its inner table.
      tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(Workbench).last,
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Scanner').hitTestable(), findsOneWidget);
      expect(map.polling, isTrue);
      final beforeClose = master.registerResults.first['numeric'] as num;
      for (
        var i = 0;
        i < 30 && master.registerResults.first['numeric'] == beforeClose;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(master.registerResults.first['numeric'], greaterThan(beforeClose));
      await workspace.remove(master);
      expect(sim.deviceRunning, isTrue);
      expect(workspace.sessions, hasLength(1));
      await workspace.shutdown();
      await tester.pumpWidget(const SizedBox());
      workspace.dispose();
      await temporary.delete(recursive: true);
      await binding.setSurfaceSize(null);
    },
  );
}

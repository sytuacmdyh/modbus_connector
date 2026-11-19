import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/desktop_table.dart';
import 'package:modbus_desktop/src/register_overview.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/settings_store.dart';
import 'package:modbus_desktop/src/translations.dart';
import 'package:modbus_desktop/src/workbench.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native TCP workspace: overview, filters, polling writes and persistence',
    (tester) async {
      binding.testTextInput.register();
      await binding.setSurfaceSize(const Size(1440, 900));
      final dir = await Directory.systemTemp.createTemp(
        'register-workspace-native-',
      );
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      final sim = NativeBridge(directory: dir.path);
      final master = SessionController(NativeBridge(directory: dir.path));
      try {
        await sim.request({
          'command': 'sim_configure',
          'rows': [
            {
              'kind': 'holding_registers',
              'address': 0,
              'count': 2,
              'values': [120, 30],
            },
            {
              'kind': 'input_registers',
              'address': 0,
              'count': 1,
              'values': [253],
            },
          ],
        });
        await sim.request({
          'command': 'device_start',
          'mode': 'simulator',
          'listen': {'transport': 'tcp', 'host': '127.0.0.1', 'port': port},
          'tick_ms': 100,
        });
        master.registers.addAll([
          {
            'name': 'Fan speed',
            'kind': 'holding_registers',
            'address': 0,
            'count': 1,
            'format': 'u16',
            'unit': 'rpm',
          },
          {
            'name': 'Pump speed',
            'kind': 'holding_registers',
            'address': 1,
            'count': 1,
            'format': 'u16',
          },
          {
            'name': 'Temperature',
            'kind': 'input_registers',
            'address': 0,
            'count': 1,
            'format': 's16',
            'scale': .1,
            'unit': '°C',
          },
        ]);
        await master.connect({
          'transport': 'tcp',
          'host': '127.0.0.1',
          'port': port,
          'timeout': .5,
        }, 1);
        await master.registerMap.read();
        expect(master.error, isNull);
        await tester.pumpWidget(
          MaterialApp(
            home: Workbench(
              controller: master,
              themeMode: ThemeMode.light,
              onThemeChanged: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        Finder tableText(String label) => find.descendant(
          of: find.byType(DesktopTable),
          matching: find.text(label),
        );
        expect(tableText('Temperature'), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('overview-value-2')),
            matching: find.text('25.3'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('overview-configure')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        expect(master.draft[overviewSettingsKey], isA<Map>());
        final before = tester
            .getSize(find.byKey(const ValueKey('register-overview-pane')))
            .width;
        await tester.drag(
          find.byKey(const ValueKey('register-split-handle')),
          const Offset(60, 0),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .getSize(find.byKey(const ValueKey('register-overview-pane')))
              .width,
          greaterThan(before + 30),
        );
        await tester.tap(find.byKey(const ValueKey('map-filter-access')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('All access').last);
        await tester.pumpAndSettle();
        expect(tableText('Temperature'), findsOneWidget);
        await tester.tap(find.text('Start polling'));
        await tester.pump(const Duration(milliseconds: 600));
        expect(master.registerMap.polling, isTrue);
        await tester.tapAt(
          tester.getTopLeft(find.byKey(const ValueKey('map-value-0'))) +
              const Offset(6, 6),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '150',
        );
        await tester.tap(find.text('Apply'));
        for (
          var i = 0;
          i < 50 && master.registerResults.first['numeric'] != 150;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(master.registerResults.first['numeric'], 150);
        expect(master.registerMap.polling, isTrue);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('overview-value-0')),
            matching: find.text('150'),
          ),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const ValueKey('map-filter-name')),
          'Fan',
        );
        await tester.pumpAndSettle();
        expect(tableText('Pump speed'), findsNothing);
        expect(find.byKey(const ValueKey('overview-value-1')), findsOneWidget);
        expect(master.registerResults, hasLength(3));
        final saved = await master.command({
          'command': 'template_save',
          'name': 'Native workspace',
          'state': master.state(),
        });
        final loaded = await master.command({
          'command': 'template_load',
          'template_id': saved!['id'],
        });
        expect(
          loaded!['state']['draft'][overviewSettingsKey],
          master.draft[overviewSettingsKey],
        );
        final store = SettingsStore(
          directory: Directory('${dir.path}/settings'),
        );
        await store.save({
          'schema': 1,
          'tabs': [jsonDecode(jsonEncode(master.state()))],
        });
        final disk = await store.load();
        expect(
          disk!['tabs'][0]['draft']['map_split_ratio'],
          master.draft['map_split_ratio'],
        );
        expect(
          disk['tabs'][0]['registers'][0][overviewRowIdKey],
          master.registers.first[overviewRowIdKey],
        );
        await tester.tap(find.text('Stop'));
        await tester.pumpAndSettle();
        appLanguage.value = 'zh_CN';
        await tester.pumpAndSettle();
        expect(find.text('配置显示'), findsOneWidget);
        expect(find.text('列设置'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await master.shutdown();
        master.dispose();
        await sim.close();
        appLanguage.value = 'en';
        await dir.delete(recursive: true);
      }
    },
  );
}

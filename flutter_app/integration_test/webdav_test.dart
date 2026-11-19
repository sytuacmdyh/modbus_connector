import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/workspace.dart';

import '../tool/webdav_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native read-only WebDAV sync during polling opens a disconnected cached template',
    (tester) async {
      binding.testTextInput.register();
      await binding.setSurfaceSize(const Size(1280, 900));
      final server = await startWebDavFixture(port: 0);
      final directory = await Directory.systemTemp.createTemp(
        'webdav-native-ui-',
      );
      final workspace = WorkspaceController(
        bridgeFactory: () => NativeBridge(directory: directory.path),
      );
      final session = workspace.sessions.first;
      session.restore({
        'connection': {'transport': 'demo'},
        'registers': [
          {'name': 'Active acquisition', 'address': 0},
        ],
      });
      try {
        await session.connect({'transport': 'demo', 'timeout': 1}, 1);
        session.registerMap.start(100);
        await tester.pumpWidget(
          MaterialApp(
            home: SessionWorkspace(
              controller: workspace,
              themeMode: ThemeMode.light,
              onThemeChanged: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Workspace'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('WebDAV sync'));
        await tester.pumpAndSettle();
        final saveSettings = find.widgetWithText(
          OutlinedButton,
          'Save connection settings',
        );
        for (
          var i = 0;
          i < 100 &&
              tester.widget<OutlinedButton>(saveSettings).onPressed == null;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          tester.widget<OutlinedButton>(saveSettings).onPressed,
          isNotNull,
        );
        expect(find.text('Mode'), findsNothing);
        expect(find.text('Publish templates'), findsNothing);
        expect(find.text('Activate version'), findsNothing);
        await tester.enterText(
          find.widgetWithText(TextField, 'WebDAV URL'),
          'http://127.0.0.1:${server.port}/dav',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Username'),
          'operator',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Password'),
          'test-only',
        );
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'WebDAV URL'))
              .controller!
              .text,
          'http://127.0.0.1:${server.port}/dav',
        );
        Future<void> waitFor(String text) async {
          for (var i = 0; i < 100 && find.text(text).evaluate().isEmpty; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            find.text(text),
            findsOneWidget,
            reason:
                'Tool errors: ${workspace.tools.map((tool) => tool.error).toList()}; dialog messages: ${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).whereType<String>().where((t) => t.contains('WebDAV') || t.contains('HTTP') || t.contains('Connection') || t == 'Working…').toList()}',
          );
        }

        await tester.tap(find.text('Test connection'));
        await waitFor('Connection successful');
        await tester.tap(find.text('Download current templates'));
        await waitFor('Synced 1 templates');
        expect(session.registerMap.polling, true);
        expect(session.busStatistics['errors'], 0);
        await tester.tap(find.text('Save connection settings'));
        await waitFor('Connection settings saved');
        expect(
          await File('${directory.path}/cloud.json').readAsString(),
          isNot(contains('test-only')),
        );
        final cached = jsonDecode(
          await File('${directory.path}/cloud_templates.json').readAsString(),
        );
        expect(cached, fixtureCatalog);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Workspace'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Templates / history'));
        await waitFor('Acme / WebDAV acceptance device');
        await tester.tap(find.text('Acme / WebDAV acceptance device'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open latest in new tab'));
        await tester.pumpAndSettle();
        expect(workspace.sessions, hasLength(2));
        expect(workspace.sessions.last.connected, false);
        expect(workspace.sessions.last.registers, hasLength(2));
        expect(workspace.sessions.last.registers[1]['writable'], false);
        expect(session.registerMap.polling, true);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await workspace.shutdown();
        workspace.dispose();
        await server.close(force: true);
        await directory.delete(recursive: true);
        await binding.setSurfaceSize(null);
        binding.testTextInput.unregister();
      }
    },
  );
}

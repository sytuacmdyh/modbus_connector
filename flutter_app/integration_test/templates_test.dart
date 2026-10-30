import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/workspace.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real templates open latest public and custom tabs with all rows', (
    tester,
  ) async {
    expect(Platform.environment['MODBUS_FLUTTER_HOME'], isNotEmpty);
    await binding.setSurfaceSize(const Size(1280, 800));
    final service = SessionController(NativeBridge());
    final workspace = WorkspaceController();
    try {
      final catalog = await service.command({'command': 'template_list'});
      expect(service.error, isNull);
      final entries = (catalog!['public'] as List).cast<Map<String, dynamic>>();
      expect(entries, isNotEmpty);
      Map<String, dynamic>? first;
      Map<String, dynamic>? largest;
      Map<String, dynamic>? largestEntry;
      for (final entry in entries) {
        final loaded = await service.command({
          'command': 'template_load',
          'resource': entry['resource'],
        });
        expect(service.error, isNull, reason: '${entry['resource']}');
        final state = loaded!['state'] as Map<String, dynamic>;
        final restored = SessionController(NativeBridge());
        try {
          restored.restore(state);
          expect(
            restored.registers,
            hasLength((state['registers'] as List).length),
            reason: '${entry['resource']} must not silently discard rows',
          );
          expect(restored.registers, isNotEmpty);
        } finally {
          await restored.shutdown();
          restored.dispose();
        }
        first ??= state;
        if (largest == null ||
            (state['registers'] as List).length >
                (largest['registers'] as List).length) {
          largest = state;
          largestEntry = entry;
        }
      }
      final saved = await service.command({
        'command': 'template_save',
        'name': 'Template acceptance custom',
        'state': first,
      });
      expect(service.error, isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: SessionWorkspace(
            controller: workspace,
            themeMode: ThemeMode.light,
            onThemeChanged: (_) {},
          ),
        ),
      );

      Future<void> openCatalog() async {
        await tester.tap(find.byTooltip('Workspace'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Templates / history'));
        for (
          var i = 0;
          i < 100 && find.text('Public (read-only)').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        for (
          var i = 0;
          i < 100 &&
              find
                  .text(
                    '${entries.first['manufacturer']} / ${entries.first['name']}',
                  )
                  .evaluate()
                  .isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
      }

      Future<void> openSelected(
        int count,
        Map<String, dynamic> expected,
      ) async {
        await tester.tap(find.text('Open latest in new tab'));
        for (var i = 0; i < 100 && workspace.sessions.length < count; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(workspace.sessions, hasLength(count));
        expect(workspace.selected, count - 1);
        expect(
          workspace.sessions.last.registers,
          hasLength((expected['registers'] as List).length),
        );
        final draft = expected['draft'] as Map;
        for (final key in ['transport', 'host', 'port', 'baud', 'timeout']) {
          expect(workspace.sessions.last.draft[key], draft[key], reason: key);
        }
        expect(workspace.sessions.last.connected, isFalse);
        expect(find.text('Open latest in new tab'), findsNothing);
        expect(tester.takeException(), isNull);
      }

      await openCatalog();
      await tester.tap(
        find.text(
          '${entries.first['manufacturer']} / ${entries.first['name']}',
        ),
      );
      await tester.pumpAndSettle();
      await openSelected(2, first!);
      expect(workspace.sessions.last.customTemplateId, isNull);

      await openCatalog();
      await tester.enterText(
        find.widgetWithText(TextField, 'Search templates'),
        'Template acceptance custom',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(ListTile, 'Template acceptance custom'),
      );
      await tester.pumpAndSettle();
      await openSelected(3, first);
      expect(workspace.sessions.last.customTemplateId, saved!['id']);

      await openCatalog();
      await tester.enterText(
        find.widgetWithText(TextField, 'Search templates'),
        largestEntry!['name'] as String,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('${largestEntry['manufacturer']} / ${largestEntry['name']}'),
      );
      await tester.pumpAndSettle();
      await openSelected(4, largest!);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await workspace.shutdown();
      workspace.dispose();
      await service.shutdown();
      service.dispose();
      await binding.setSurfaceSize(null);
    }
  });
}

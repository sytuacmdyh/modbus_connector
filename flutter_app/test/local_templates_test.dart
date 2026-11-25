import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/templates_dialog.dart';
import 'package:modbus_desktop/src/translations.dart';
import 'package:modbus_desktop/src/workspace.dart';

import 'fake_bridge.dart';

class LocalCatalogBridge extends FakeBridge {
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    if (command['command'] == 'template_list') {
      calls.add(command);
      return const BridgeReply({'public': [], 'custom': []}, false);
    }
    return super.request(command, timeout: timeout);
  }
}

void main() {
  const channel = MethodChannel('plugins.flutter.io/file_selector');
  late Directory directory;
  late File file;
  setUp(() {
    appLanguage.value = 'en';
    directory = Directory.systemTemp.createTempSync('local-template-test-');
    file = File('${directory.path}/device.json');
    file.writeAsStringSync(
      jsonEncode({
        'name': 'Local device',
        'connection': {'type': 'TCP', 'tcp_host': '192.0.2.1', 'tcp_port': 502},
        'registers': [
          {'name': 'Mode', 'address': 7, 'format': 'dec'},
        ],
      }),
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  Future<void> showTemplates(
    WidgetTester tester,
    WorkspaceController workspace,
  ) async {
    tester.view.physicalSize = const Size(900, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SessionController(LocalCatalogBridge());
    addTearDown(() async {
      await session.shutdown();
      session.dispose();
    });
    addTearDown(() async {
      await workspace.shutdown();
      workspace.dispose();
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TemplatesDialog(
                  session: session,
                  onOpen: (state, id) =>
                      workspace.openState(state, templateId: id),
                ),
              ),
              child: const Text('Templates'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Templates'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'local file opens a disconnected tab and leaves source untouched',
    (tester) async {
      final workspace = WorkspaceController(bridgeFactory: FakeBridge.new);
      await showTemplates(tester, workspace);
      final before = workspace.sessions.length;
      final original = file.readAsStringSync();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => [file.path],
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Choose local template file'));
        for (var i = 0; i < 100 && workspace.sessions.length == before; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(workspace.sessions.length, before + 1);
      final opened = workspace.sessions.last;
      expect(opened.connected, false);
      expect(opened.customTemplateId, isNull);
      expect(opened.registers.single['address'], 7);
      expect(opened.draft['host'], '192.0.2.1');
      expect((opened.bridge as FakeBridge).calls, isEmpty);
      expect(file.readAsStringSync(), original);
      expect(find.byType(TemplatesDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancel and invalid file preserve tabs and allow another selection',
    (tester) async {
      final workspace = WorkspaceController(bridgeFactory: FakeBridge.new);
      await showTemplates(tester, workspace);
      final before = workspace.sessions.length;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      await tester.tap(find.text('Choose local template file'));
      await tester.pumpAndSettle();
      expect(workspace.sessions.length, before);
      file.writeAsStringSync('{');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => [file.path],
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Choose local template file'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('Invalid template JSON'), findsOneWidget);
      expect(workspace.sessions.length, before);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Choose local template file'),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closed dialog suppresses a late file selection', (tester) async {
    final workspace = WorkspaceController(bridgeFactory: FakeBridge.new);
    await showTemplates(tester, workspace);
    final before = workspace.sessions.length;
    final picked = Completer<List<String>?>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) => picked.future,
    );
    await tester.tap(find.text('Choose local template file'));
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    picked.complete([file.path]);
    await tester.pumpAndSettle();
    expect(workspace.sessions.length, before);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/main.dart';
import 'package:modbus_desktop/src/diagnostics.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets('diagnostic buttons export prompt and confirmed clear', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync('diagnostics-ui-');
    final log = Diagnostics(root, includeSystemDumps: false)
      ..write('session', 'keep until confirmed');
    Diagnostics.current = log;
    addTearDown(() {
      Diagnostics.current = null;
      root.deleteSync(recursive: true);
    });
    const channel = MethodChannel('plugins.flutter.io/file_selector');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => throw MissingPluginException(),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final session = SessionController(FakeBridge());
    await tester.pumpWidget(ModbusApp(controller: session));
    await tester.tap(find.byKey(const ValueKey('export-diagnostics')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('clear-diagnostics')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(log.logFiles(), isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('clear-diagnostics')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Clear logs'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(log.logFiles(), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
}

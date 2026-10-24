import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/main.dart';
import 'package:modbus_desktop/src/help_dialog.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/translations.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets('live Chinese UI and help use centralized translations', (
    tester,
  ) async {
    final session = SessionController(FakeBridge());
    await tester.pumpWidget(ModbusApp(controller: session));
    expect(find.text('Connect'), findsOneWidget);
    appLanguage.value = 'zh_CN';
    await tester.pumpAndSettle();
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFeatureHelp(context),
            child: const Text('help'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('help'));
    await tester.pumpAndSettle();
    expect(find.text('帮助 / 功能指南'), findsOneWidget);
    expect(find.textContaining('使用 + 添加独立会话'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    appLanguage.value = 'en';
    session.dispose();
  });
}

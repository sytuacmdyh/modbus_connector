import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/main.dart';
import 'package:modbus_desktop/src/help_dialog.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/translations.dart';

import 'fake_bridge.dart';

void main() {
  test(
    'dynamic prompts and technical validation errors translate in Chinese',
    () {
      appLanguage.value = 'zh_CN';
      expect(tr('count must be an integer in 1..125'), '数量 必须是 1 到 125 之间的整数');
      expect(tr('Snapshot baseline differences'), '快照 baseline 的差异');
      expect(
        tr('Write Voltage (f32, engineering units)'),
        '写入 Voltage（f32，工程单位）',
      );
      expect(tr('Logging · 12 samples written'), '记录中 · 已写入 12 个样本');
      expect(tr('Unknown register area or display format'), '未知的寄存器区域或显示格式');
      expect(tr('Invalid rule syntax'), '规则语法无效');
      appLanguage.value = 'en';
      expect(
        tr('count must be an integer in 1..125'),
        'count must be an integer in 1..125',
      );
    },
  );

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

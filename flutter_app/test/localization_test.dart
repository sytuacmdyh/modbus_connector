import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/main.dart';
import 'package:modbus_desktop/src/help_dialog.dart';
import 'package:modbus_desktop/src/register_map.dart';
import 'package:modbus_desktop/src/scanner.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/translations.dart';

import 'fake_bridge.dart';

void main() {
  tearDown(() => appLanguage.value = 'en');

  test('area, activity and composite probe/curve labels follow language', () {
    const labels = {
      'Holding registers': '保持寄存器',
      'Input registers': '输入寄存器',
      'Coils': '线圈',
      'Discrete inputs': '离散输入',
      'Register': '寄存器',
      'dec': '十进制 (dec)',
      'Connecting…': '正在连接…',
      'Connected · tcp localhost:502 · unit 3':
          '已连接 · tcp localhost:502 · 站号 3',
      'Polling every 500 ms': '正在轮询，间隔 500 毫秒',
      'Polling stopped': '轮询已停止',
      'Read 2 holding_registers @5 · 1.2 ms': '已读取 2 个保持寄存器 @5 · 1.2 毫秒',
      'Wrote 42 → coils @6': '已写入 42 → 线圈 @6',
      'holding_registers @0 × 1': '保持寄存器 @0 × 1',
      'input_registers @10 × 2': '输入寄存器 @10 × 2',
      'coils @0 × 1': '线圈 @0 × 1',
      'Unit 2 · probes [0, 2]': '站号 2 · 探测项 [0, 2]',
      'holding_registers @5': '保持寄存器 @5',
      'unit 2 discrete_inputs @7': '站号 2 离散输入 @7',
      'input_registers/10': '输入寄存器/10',
    };
    for (final language in ['zh_CN', 'en']) {
      appLanguage.value = language;
      for (final entry in labels.entries) {
        expect(
          tr(entry.key),
          language == 'en' ? entry.key : entry.value,
          reason: '${entry.key} in $language',
        );
      }
    }
  });

  testWidgets('existing activity and quick-area headers change language live', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SessionController(FakeBridge());
    await session.connect({'timeout': 0.1}, 3);
    session.startPolling();
    session.stopPolling();
    await tester.pumpWidget(ModbusApp(controller: session));
    for (final language in ['zh_CN', 'en']) {
      appLanguage.value = language;
      await tester.pumpAndSettle();
      final chinese = language == 'zh_CN';
      expect(
        find.textContaining(chinese ? '正在连接…' : 'Connecting…'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          chinese ? '已连接 · test TCP · 站号 3' : 'Connected · test TCP · unit 3',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          chinese ? '正在轮询，间隔 500 毫秒' : 'Polling every 500 ms',
        ),
        findsOneWidget,
      );
      for (final kind in areas.keys) {
        session.setQuery(ReadQuery(kind: kind, count: 1));
        await tester.pumpAndSettle();
        expect(find.text(tr(areas[kind]!.split(' · ').first)), findsOneWidget);
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('Chinese row default is saved, edited user names are preserved', (
    tester,
  ) async {
    appLanguage.value = 'zh_CN';
    final session = SessionController(FakeBridge());
    await tester.pumpWidget(
      MaterialApp(home: RegisterMapDialog(session: session)),
    );
    await tester.tap(find.text('添加行'));
    await tester.pumpAndSettle();
    final name = find.widgetWithText(TextField, '名称');
    expect(tester.widget<TextField>(name).controller!.text, '寄存器');
    expect(find.text('十进制 (dec)'), findsWidgets);
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(session.registers.single['name'], '寄存器');
    expect(session.registers.single['format'], 'dec');
    expect(session.registers.single['kind'], 'holding_registers');
    await tester.tap(find.text('寄存器'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名称'), 'Voltage');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(session.registers.single['name'], 'Voltage');
    expect(find.text('Voltage'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('scanner translates probes and recalled unit hits live', (
    tester,
  ) async {
    final session = SessionController(FakeBridge());
    session.scannerState['hits'] = [
      {
        'unit': 2,
        'hits': [0, 2],
      },
    ];
    await tester.pumpWidget(MaterialApp(home: ScannerDialog(session: session)));
    expect(find.text('holding_registers @0 × 1'), findsOneWidget);
    appLanguage.value = 'zh_CN';
    await tester.pumpAndSettle();
    expect(find.text('保持寄存器 @0 × 1'), findsOneWidget);
    expect(find.text('输入寄存器 @0 × 1'), findsOneWidget);
    // The third probe is in the independently scrollable probe list.
    await tester.drag(find.byType(ListView).first, const Offset(0, -70));
    await tester.pumpAndSettle();
    expect(find.text('线圈 @0 × 1'), findsOneWidget);
    expect(find.text('站号 2 · 探测项 [0, 2]'), findsOneWidget);
    appLanguage.value = 'en';
    await tester.pumpAndSettle();
    expect(find.text('coils @0 × 1'), findsOneWidget);
    expect(find.text('Unit 2 · probes [0, 2]'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  test('remaining Flutter captions and dynamic titles translate both ways', () {
    final captions = [
      'Read',
      'Activity',
      'Hex',
      'Scanner',
      'Close',
      'Apply',
      'Write',
      'Advanced Modbus',
      'Settings',
      'Device / diagnostics',
      'Find serial ports',
      'Manage views',
      'Move column left',
      'Reset columns',
      'Automatically save workspace',
      'No serial ports found. You can type a port manually.',
    ];
    appLanguage.value = 'zh_CN';
    for (final caption in captions) {
      expect(tr(caption), isNot(caption), reason: caption);
    }
    expect(tr('Live trend · @42'), '实时趋势 · @42');
    expect(tr('Write register @5'), '写入寄存器 @5');
    expect(tr('Advanced Modbus · unit 3'), '高级 Modbus · 站号 3');
    appLanguage.value = 'en';
    for (final caption in captions) {
      expect(tr(caption), caption);
    }
  });

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

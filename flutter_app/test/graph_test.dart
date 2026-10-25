import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/graph_dialog.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/translations.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets(
    'graph restores curve selection, scale and time window when reopened',
    (tester) async {
      final session = SessionController(FakeBridge());
      session.recordPoint('v', 'Voltage', 230);
      session.recordPoint('i', 'Current', 5);
      session.draft['graph:master'] = {
        'selected': ['i'],
        'seconds': 300,
        'normalized': true,
      };
      await tester.pumpWidget(MaterialApp(home: GraphDialog(session: session)));
      expect(
        tester
            .widget<CheckboxListTile>(
              find.ancestor(
                of: find.text('Current'),
                matching: find.byType(CheckboxListTile),
              ),
            )
            .value,
        true,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.ancestor(
                of: find.text('Voltage'),
                matching: find.byType(CheckboxListTile),
              ),
            )
            .value,
        false,
      );
      expect(find.text('300'), findsOneWidget);
      await tester.tap(find.text('Normalize each curve'));
      await tester.pumpAndSettle();
      expect((session.draft['graph:master'] as Map)['normalized'], false);
      expect(find.text('Reset zoom'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('area curve legends and statistics change language live', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => appLanguage.value = 'en');
    final session = SessionController(FakeBridge());
    await session.connect({'timeout': 0.1}, 1);
    session.recordPoint('1/holding_registers/0', 'holding_registers @0', 100);
    session.recordPoint('sniff/2/coils/7', 'unit 2 coils @7', 1);
    session.recordPoint('custom', 'Voltage', 230);
    await tester.pumpWidget(MaterialApp(home: GraphDialog(session: session)));
    expect(find.text('holding_registers @0'), findsOneWidget);
    appLanguage.value = 'zh_CN';
    await tester.pumpAndSettle();
    expect(find.text('保持寄存器 @0'), findsOneWidget);
    expect(find.textContaining('保持寄存器 @0: 100.000'), findsOneWidget);
    expect(find.text('站号 2 线圈 @7'), findsOneWidget);
    expect(find.textContaining('站号 2 线圈 @7: 1.00000'), findsOneWidget);
    expect(find.text('Voltage'), findsOneWidget);
    expect(find.textContaining('Voltage: 230.000'), findsOneWidget);
    expect(find.textContaining('holding_registers'), findsNothing);
    appLanguage.value = 'en';
    await tester.pumpAndSettle();
    expect(find.text('holding_registers @0'), findsOneWidget);
    expect(
      find.textContaining('holding_registers @0: 100.000'),
      findsOneWidget,
    );
    expect(
      session.historyLabels['1/holding_registers/0'],
      'holding_registers @0',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets(
    'sniffer unit graph selection and clearing stay within that unit',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final session = SessionController(FakeBridge());
      session.recordPoint(
        'sniff-view/1/holding_registers/0',
        'Unit one voltage',
        2,
      );
      final firstHistory =
          session.histories['sniff-view/1/holding_registers/0']!;
      firstHistory
        ..clear()
        ..add(Sample(DateTime(2026), 2));
      session.recordPoint(
        'sniff-view/2/holding_registers/0',
        'Unit two voltage',
        3,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: GraphDialog(session: session, historyPrefix: 'sniff-view/1/'),
        ),
      );
      expect(find.text('Unit one voltage'), findsWidgets);
      expect(find.text('Unit two voltage'), findsNothing);
      // Traffic in another unit must not advance this unit's time window.
      expect(find.textContaining('Unit one voltage: 2.00000'), findsOneWidget);
      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(session.histories['sniff-view/1/holding_registers/0'], isEmpty);
      expect(
        session.histories['sniff-view/2/holding_registers/0'],
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('graph exports a real PNG with native save selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temporary = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('graph-png-test'),
    ))!;
    final output = File('${temporary.path}/graph.png');
    const channel = MethodChannel('plugins.flutter.io/file_selector');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => output.path,
    );
    final session = SessionController(FakeBridge());
    session.recordPoint('v', 'Voltage', 230);
    await tester.pumpWidget(MaterialApp(home: GraphDialog(session: session)));
    await tester.tap(find.text('Export PNG'));
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      // The file may exist before writeAsBytes has flushed/closed on Windows.
      if (find.textContaining('Saved ').evaluate().isNotEmpty) break;
    }
    final bytes = (await tester.runAsync(output.readAsBytes))!;
    expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(bytes.length, greaterThan(100));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
    await tester.runAsync(() => temporary.delete(recursive: true));
  });

  test('nearest sample uses timestamps across uneven sample intervals', () {
    final origin = DateTime(2026);
    final samples = [
      Sample(origin, 1),
      Sample(origin.add(const Duration(seconds: 1)), 2),
      Sample(origin.add(const Duration(seconds: 100)), 3),
    ];
    expect(
      nearestGraphSample(
        samples,
        origin.add(const Duration(seconds: 3)),
      )!.value,
      2,
    );
    expect(
      nearestGraphSample(
        samples,
        origin.add(const Duration(seconds: 90)),
      )!.value,
      3,
    );
    expect(nearestGraphSample([], origin), isNull);
  });

  testWidgets(
    'graph shows multiple numeric curves, statistics, pause and normalization',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SessionController(FakeBridge());
      session.recordPoint('a', 'Voltage', 230);
      session.recordPoint('b', 'Current', 5);
      await tester.pumpWidget(MaterialApp(home: GraphDialog(session: session)));
      expect(find.textContaining('Voltage:'), findsOneWidget);
      expect(find.textContaining('Current:'), findsOneWidget);
      await tester.tap(find.text('Normalize each curve'));
      await tester.pump();
      await tester.tap(find.text('Pause chart'));
      await tester.pump();
      expect(find.text('Resume chart'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}

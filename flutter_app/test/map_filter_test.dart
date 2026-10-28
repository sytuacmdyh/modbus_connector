import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/desktop_table.dart';
import 'package:modbus_desktop/src/register_map.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

Map<String, dynamic> row(
  String name,
  int address, {
  String kind = 'holding_registers',
  int count = 1,
  bool? polling,
}) => {
  'name': name,
  'address': address,
  'kind': kind,
  'count': count,
  'format': 'dec',
  'poll_enabled': ?polling,
};

Future<void> mountMap(WidgetTester tester, SessionController session) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: RegisterMapPanel(session: session, autofocus: true)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> chooseFilter(WidgetTester tester, String key, String label) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> selectedAction(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Selected rows'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

List<int> readAddresses(FakeBridge bridge) => bridge.calls
    .where((c) => c['command'] == 'read_rows')
    .expand((c) => (c['rows'] as List).map((r) => r['address'] as int))
    .toList();

void main() {
  testWidgets(
    'combined filters match address spans without restricting polling',
    (tester) async {
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      session.registers.addAll([
        row('Temperature inlet', 100, count: 2),
        row('Pressure', 101),
        row('TEMPERATURE outlet', 108, polling: false),
        row('Temperature coil', 108, kind: 'coils'),
        row('Temperature far', 200),
      ]);
      await session.connect({'timeout': 0.1}, 1);
      await mountMap(tester, session);
      await tester.enterText(
        find.byKey(const ValueKey('map-filter-name')),
        ' tEmP ',
      );
      await tester.pumpAndSettle();
      expect(find.text('Showing 4 / 5'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('map-filter-address')),
        '0x65–0x8',
      );
      await tester.pumpAndSettle();
      expect(find.text('Showing 3 / 5'), findsOneWidget);
      await chooseFilter(tester, 'map-filter-polling', 'Enabled only');
      expect(find.text('Showing 2 / 5'), findsOneWidget);
      await chooseFilter(tester, 'map-filter-area', 'Holding registers · 03');
      expect(find.text('Showing 1 / 5'), findsOneWidget);
      expect(find.text('Temperature inlet'), findsOneWidget);
      expect(find.text('Pressure'), findsNothing);
      bridge.calls.clear();
      session.registerMap.start(500);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pumpAndSettle();
      expect(session.registerMap.polling, isTrue);
      expect(readAddresses(bridge).toSet(), {100, 101, 108, 200});
      expect(session.registers[2]['poll_enabled'], isFalse);
      session.registerMap.stop();
      await chooseFilter(tester, 'map-filter-polling', 'Disabled only');
      expect(find.text('TEMPERATURE outlet'), findsOneWidget);
      expect(find.text('Temperature inlet'), findsNothing);
    },
  );

  testWidgets(
    'address-count filter covers exactly count addresses with overlap',
    (tester) async {
      final session = SessionController(FakeBridge());
      session.registers.addAll([
        row('Overlap', 99, count: 2),
        row('First', 100),
        row('Last', 119),
        row('Outside', 120),
        row('Top', 65535),
      ]);
      await mountMap(tester, session);
      final input = find.byKey(const ValueKey('map-filter-address'));
      for (final text in ['100-20', '0x64-0x14']) {
        await tester.enterText(input, text);
        await tester.pumpAndSettle();
        expect(find.text('Showing 3 / 5'), findsOneWidget);
        expect(find.text('Overlap'), findsOneWidget);
        expect(find.text('Last'), findsOneWidget);
        expect(find.text('Outside'), findsNothing);
      }
      await tester.enterText(input, '65535-1');
      await tester.pumpAndSettle();
      expect(find.text('Showing 1 / 5'), findsOneWidget);
      expect(find.text('Top'), findsOneWidget);
    },
  );

  testWidgets(
    'filtered selection, writes, moves and deletes use original rows',
    (tester) async {
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      session.registers.addAll([
        row('keep A', 10),
        row('skip B', 11),
        row('keep C', 12),
        row('skip D', 13),
        row('keep E', 14),
      ]);
      await session.connect({'timeout': 0.1}, 1);
      await mountMap(tester, session);
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.enterText(
        find.byKey(const ValueKey('map-filter-name')),
        'keep',
      );
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(3));
      expect(
        tester.widgetList<Checkbox>(find.byType(Checkbox)).map((c) => c.value),
        [false, false, false],
      );
      await tester.tap(find.byTooltip('Select all / clear'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((c) => c.value!),
        isTrue,
      );
      await tester.tap(find.byTooltip('Select all / clear'));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Checkbox).first),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(tester.getCenter(find.byType(Checkbox).at(1)));
      await gesture.up();
      await gesture.removePointer();
      await tester.pumpAndSettle();
      bridge.calls.clear();
      await selectedAction(tester, 'Read selected rows');
      expect(readAddresses(bridge), [10, 12]);
      await tester.tap(find.byKey(const ValueKey('disable-selected-polling')));
      await tester.pumpAndSettle();
      expect(session.registers.map((r) => r['poll_enabled'] != false), [
        false,
        true,
        false,
        true,
        true,
      ]);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      bridge.calls.clear();
      await selectedAction(tester, 'Write 1');
      expect(
        bridge.calls.singleWhere((c) => c['command'] == 'write')['address'],
        12,
      );
      await selectedAction(tester, 'Move up');
      expect(session.registers.map((r) => r['name']), [
        'keep C',
        'skip B',
        'keep A',
        'skip D',
        'keep E',
      ]);
      await selectedAction(tester, 'Delete selected rows');
      expect(session.registers.map((r) => r['name']), [
        'skip B',
        'keep A',
        'skip D',
        'keep E',
      ]);
      await tester.tap(find.text('keep E'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Name'))
            .controller!
            .text,
        'keep E',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'keep F');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(session.registers.last['name'], 'keep F');
      expect(session.registers.last['address'], 14);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid and empty results clear without changing register data',
    (tester) async {
      final session = SessionController(FakeBridge());
      session.registers.addAll([row('First', 0), row('Last', 65535)]);
      await mountMap(tester, session);
      for (final address in [
        '-1',
        '65536',
        '65535-2',
        '1-0',
        '0-65537',
        '1-',
        'abc',
      ]) {
        await tester.enterText(
          find.byKey(const ValueKey('map-filter-address')),
          address,
        );
        await tester.pumpAndSettle();
        expect(find.text('Invalid address range'), findsOneWidget);
        expect(find.text('Showing 0 / 2'), findsOneWidget);
        expect(find.text('No registers match the filters.'), findsOneWidget);
      }
      await tester.enterText(
        find.byKey(const ValueKey('map-filter-address')),
        '0',
      );
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Last'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('map-filter-address')),
        '0xFFFF',
      );
      await tester.pumpAndSettle();
      expect(find.text('Last'), findsOneWidget);
      expect(find.text('Invalid address range'), findsNothing);
      await chooseFilter(tester, 'map-filter-polling', 'Disabled only');
      await chooseFilter(tester, 'map-filter-area', 'Coils · 01');
      await tester.tap(find.byTooltip('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Showing 2 / 2'), findsOneWidget);
      expect(find.text('All rows'), findsOneWidget);
      expect(find.text('All areas'), findsOneWidget);
      expect(session.registers.map((r) => r['address']), [0, 65535]);
      expect(
        session.registers.every((r) => !r.containsKey('poll_enabled')),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'typing filter shortcuts cannot select delete or write map rows',
    (tester) async {
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      session.registers.addAll([row('First', 0), row('Second', 1)]);
      await session.connect({'timeout': 0.1}, 1);
      await mountMap(tester, session);
      await tester.tap(find.byType(Checkbox).first);
      final name = find.byKey(const ValueKey('map-filter-name'));
      await tester.tap(name);
      await tester.pumpAndSettle();
      bridge.calls.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(session.registers, hasLength(2));
      expect(bridge.calls, isEmpty);
      expect(
        tester.widgetList<Checkbox>(find.byType(Checkbox)).map((c) => c.value),
        [true, false],
      );
      await tester.enterText(name, 'First');
      await tester.pumpAndSettle();
      expect(find.text('Showing 1 / 2'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(name).controller!.text, isEmpty);
      expect(session.registers, hasLength(2));
    },
  );

  testWidgets(
    'polling filter removes changed rows and disables hidden selection',
    (tester) async {
      final session = SessionController(FakeBridge());
      session.registers.addAll([
        row('Enabled', 0),
        row('Paused', 1, polling: false),
        row('Also enabled', 2),
      ]);
      await mountMap(tester, session);
      await chooseFilter(tester, 'map-filter-polling', 'Enabled only');
      await tester.tap(find.byTooltip('Select all / clear'));
      await tester.pumpAndSettle();
      final disable = find.byKey(const ValueKey('disable-selected-polling'));
      await tester.tap(disable);
      await tester.pumpAndSettle();
      expect(find.text('Showing 0 / 3'), findsOneWidget);
      expect(disable, findsNothing);
      expect(
        session.registers.every((r) => r['poll_enabled'] == false),
        isTrue,
      );
      await chooseFilter(tester, 'map-filter-polling', 'All rows');
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((c) => !c.value!),
        isTrue,
      );
      expect(
        tester.widget<DesktopTable>(find.byType(DesktopTable)).rowCount,
        3,
      );
    },
  );
}

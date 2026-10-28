import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/register_map.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

Map<String, dynamic> row(String name, int address, {int count = 1}) => {
  'name': name,
  'kind': 'holding_registers',
  'address': address,
  'count': count,
  'format': 'dec',
};

void main() {
  test(
    'presets trim sparse pages, clip crossing rows and skip empty pages',
    () {
      final session = SessionController(FakeBridge());
      addTearDown(session.dispose);
      session.registers.addAll([
        row('High', 1065, count: 2),
        row('Low', 1001, count: 2),
        row('Inside', 108, count: 2),
        row('Crossing', 98, count: 4),
        row('Single', 224),
        row('Last', 65535),
        row('Invalid', 65535, count: 2),
        row('Empty', 300, count: 0),
        row('Negative', -1),
      ]);
      expect(session.registerMap.addressPresets, [
        (pageStart: 0, start: 98, count: 2),
        (pageStart: 100, start: 100, count: 10),
        (pageStart: 200, start: 224, count: 1),
        (pageStart: 1000, start: 1001, count: 66),
        (pageStart: 65500, start: 65535, count: 1),
      ]);
    },
  );

  test('preset choices follow the current map after replacement and edits', () {
    final session = SessionController(FakeBridge());
    addTearDown(session.dispose);
    expect(session.registerMap.addressPresets, isEmpty);
    session.registers.add(row('Original', 2, count: 34));
    expect(session.registerMap.addressPresets.single, (
      pageStart: 0,
      start: 2,
      count: 34,
    ));
    session.registers
      ..clear()
      ..add(row('Replacement', 1200, count: 2));
    expect(session.registerMap.addressPresets.single, (
      pageStart: 1200,
      start: 1200,
      count: 2,
    ));
    session.registers.single['count'] = 83;
    expect(session.registerMap.addressPresets.single, (
      pageStart: 1200,
      start: 1200,
      count: 83,
    ));
  });

  testWidgets(
    'presets fill the filter without changing polling or other filters',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      session.registers.addAll([
        row('keep A', 103, count: 2),
        row('skip B', 120),
        row('keep C', 201),
      ]);
      await session.connect({'timeout': .1}, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RegisterMapPanel(session: session)),
        ),
      );
      await tester.pumpAndSettle();
      session.registerMap.start(5000);
      await tester.pump();
      final callsBefore = bridge.calls.length;
      await tester.enterText(
        find.byKey(const ValueKey('map-filter-name')),
        'keep',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      Future<void> choose(String label) async {
        await tester.tap(find.byKey(const ValueKey('map-address-presets')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      final address = find.byKey(const ValueKey('map-filter-address'));
      await choose('100–199 · 103-18');
      expect(tester.widget<TextField>(address).controller!.text, '103-18');
      expect(find.text('keep A'), findsOneWidget);
      expect(find.text('keep C'), findsNothing);
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((c) => c.value == false),
        isTrue,
      );
      await choose('200–299 · 201-1');
      expect(tester.widget<TextField>(address).controller!.text, '201-1');
      expect(find.text('keep C'), findsOneWidget);
      await choose('All addresses');
      expect(tester.widget<TextField>(address).controller!.text, isEmpty);
      expect(find.text('Showing 2 / 3'), findsOneWidget);
      await tester.enterText(address, '103-1');
      await tester.pumpAndSettle();
      expect(find.text('keep A'), findsOneWidget);
      expect(find.text('keep C'), findsNothing);
      expect(session.registerMap.polling, isTrue);
      expect(session.registers, hasLength(3));
      expect(bridge.calls, hasLength(callsBefore));
      expect(tester.takeException(), isNull);
      session.registerMap.stop();
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}

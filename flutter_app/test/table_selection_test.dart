import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/desktop_table.dart';
import 'package:modbus_desktop/src/register_map.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets(
    'mouse sweep toggles each crossed row once, with skipped and reversed rows',
    (tester) async {
      final selected = <int>{1};
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) => Scaffold(
              body: DesktopTable(
                columns: const [
                  TableColumnSpec('name', 'Name', 150),
                  TableColumnSpec('select', 'Select', 70),
                ],
                layout: {
                  'compact': true,
                  'order': ['name', 'select'],
                },
                rowCount: 20,
                selectionColumn: 'select',
                selected: selected.contains,
                onToggleRows: (rows) => update(() {
                  for (final row in rows) {
                    if (!selected.add(row)) selected.remove(row);
                  }
                }),
                cellBuilder: (_, row, key) => key == 'name'
                    ? Text('row$row')
                    : Checkbox(
                        key: ValueKey('check$row'),
                        value: selected.contains(row),
                        onChanged: (_) => update(() {
                          if (!selected.add(row)) selected.remove(row);
                        }),
                      ),
              ),
            ),
          ),
        ),
      );
      final from = tester.getCenter(find.byKey(const ValueKey('check0')));
      final to = tester.getCenter(find.byKey(const ValueKey('check3')));
      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(to);
      await tester.pump();
      expect(selected, {0, 2, 3});
      await gesture.moveTo(from);
      await tester.pump();
      expect(selected, {0, 2, 3});
      await gesture.up();
      await gesture.removePointer();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('check0')));
      await tester.pump();
      expect(selected, {2, 3});
      final otherColumn = await tester.startGesture(
        tester.getCenter(find.text('row0')),
        kind: PointerDeviceKind.mouse,
      );
      await otherColumn.moveBy(const Offset(0, 100));
      await otherColumn.up();
      await otherColumn.removePointer();
      await tester.pump();
      expect(selected, {2, 3});
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'sweep auto-scrolls a virtual map and cancels on release/disposal',
    (tester) async {
      final selected = <int>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 280,
              child: DesktopTable(
                columns: const [
                  TableColumnSpec('select', 'Select', 70),
                  TableColumnSpec('name', 'Name', 150),
                ],
                layout: {},
                rowCount: 512,
                selectionColumn: 'select',
                onToggleRows: selected.addAll,
                cellBuilder: (_, row, key) => key == 'select'
                    ? Checkbox(
                        key: ValueKey('check$row'),
                        value: false,
                        onChanged: (_) {},
                      )
                    : Text('row$row'),
              ),
            ),
          ),
        ),
      );
      final from = tester.getCenter(find.byKey(const ValueKey('check0')));
      final table = tester.getRect(find.byType(DesktopTable));
      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(Offset(from.dx, table.bottom - 4));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(selected.length, greaterThan(10));
      expect(selected, containsAll(List.generate(selected.length, (i) => i)));
      await gesture.up();
      await gesture.removePointer();
      final count = selected.length;
      await tester.pump(const Duration(seconds: 1));
      expect(selected.length, count);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'toolbar polling actions affect only selected rows and persist to workspace',
    (tester) async {
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      session.registers.addAll(
        List.generate(
          3,
          (i) => <String, dynamic>{
            'name': 'row$i',
            'kind': 'holding_registers',
            'address': i,
            'count': 1,
            'poll_enabled': true,
          },
        ),
      );
      await session.connect({'transport': 'tcp', 'timeout': 1}, 1);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RegisterMapPanel(session: session))),
      );
      await tester.pumpAndSettle();
      final enable = find.byKey(const ValueKey('enable-selected-polling'));
      final disable = find.byKey(const ValueKey('disable-selected-polling'));
      expect(tester.widget<OutlinedButton>(enable).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(disable).onPressed, isNull);
      final tableTop = tester.getTopLeft(find.byType(DesktopTable));
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pump();
      expect(tester.getTopLeft(find.byType(DesktopTable)), tableTop);
      await tester.tap(disable);
      await tester.pumpAndSettle();
      expect(session.registers.map((r) => r['poll_enabled']), [
        false,
        false,
        true,
      ]);
      final reopened = SessionController(FakeBridge())
        ..restore(session.state());
      expect(reopened.registers.map((r) => r['poll_enabled']), [
        false,
        false,
        true,
      ]);
      reopened.dispose();
      expect(find.byIcon(Icons.pause_circle_outline), findsNWidgets(2));
      await session.registerMap.read();
      expect(
        bridge.calls
            .where((c) => c['command'] == 'read_rows')
            .expand((c) => (c['rows'] as List).map((r) => r['address'])),
        [2],
      );
      await tester.pumpAndSettle();
      await tester.tap(enable);
      await tester.pumpAndSettle();
      expect(session.registers.every((r) => r['poll_enabled'] == true), isTrue);
      expect(find.byIcon(Icons.pause_circle_outline), findsNothing);
      expect(
        tester.widgetList<Checkbox>(find.byType(Checkbox)).map((c) => c.value),
        [true, true, false],
      );
      bridge.calls.clear();
      await session.registerMap.read();
      expect(
        bridge.calls
            .where((c) => c['command'] == 'read_rows')
            .expand((c) => (c['rows'] as List).map((r) => r['address'])),
        [0, 1, 2],
      );
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'single selection column preserves polling flags and batch menu toggles them',
    (tester) async {
      final session = SessionController(FakeBridge());
      session.registers.addAll(
        List.generate(
          3,
          (i) => <String, dynamic>{
            'name': 'row$i',
            'kind': 'holding_registers',
            'address': i,
            'count': 1,
            'format': 'dec',
            'poll_enabled': i != 1,
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: RegisterMapDialog(session: session)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Poll enabled'), findsNothing);
      expect(find.byType(Checkbox), findsNWidgets(3));
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
      await tester.ensureVisible(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      final first = tester.getCenter(find.byType(Checkbox).first);
      final last = tester.getCenter(find.byType(Checkbox).last);
      final gesture = await tester.startGesture(
        first,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(last);
      await gesture.up();
      await gesture.removePointer();
      await tester.pump();
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((c) => c.value!),
        isTrue,
      );
      expect(session.registers.map((r) => r['poll_enabled']), [
        true,
        false,
        true,
      ]);
      await tester.ensureVisible(find.byTooltip('Selected rows'));
      await tester.tap(find.byTooltip('Selected rows'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disable selected polling'));
      await tester.pumpAndSettle();
      expect(
        session.registers.every((r) => r['poll_enabled'] == false),
        isTrue,
      );
      expect(find.byIcon(Icons.pause_circle_outline), findsNWidgets(3));
      await tester.tap(find.byTooltip('Selected rows'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enable selected polling'));
      await tester.pumpAndSettle();
      expect(session.registers.every((r) => r['poll_enabled'] == true), isTrue);
      expect(find.byIcon(Icons.pause_circle_outline), findsNothing);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/desktop_table.dart';

void main() {
  for (final offset in [-3.0, 0.0, 3.0]) {
    testWidgets('mouse resizes at column boundary offset $offset', (
      tester,
    ) async {
      final layout = <String, dynamic>{};
      Widget table() => MaterialApp(
        home: Scaffold(
          body: DesktopTable(
            columns: const [
              TableColumnSpec('name', 'Name', 150),
              TableColumnSpec('value', 'Value', 200),
            ],
            layout: layout,
            rowCount: 1,
            cellBuilder: (_, i, key) => Text('$key-$i'),
          ),
        ),
      );
      await tester.pumpWidget(table());
      final name = find.byKey(const ValueKey('column-name'));
      final rect = tester.getRect(name);
      final start = Offset(rect.right + offset, rect.center.dy);
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      for (var dx = 4.0; dx <= 40; dx += 4) {
        await gesture.moveTo(start + Offset(dx, 0));
        await tester.pump();
      }
      await gesture.up();
      await gesture.removePointer();
      await tester.pumpAndSettle();
      expect(tester.getSize(name).width, closeTo(190, 1));
      expect(layout['order'], isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(table());
      expect(tester.getSize(name).width, closeTo(190, 1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('resizing scrolled, reordered headers keeps rows aligned', (
    tester,
  ) async {
    final layout = <String, dynamic>{
      'order': ['value', 'hidden', 'name'],
      'hidden': ['hidden'],
      'widths': {'value': 300.0, 'name': 200.0},
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: DesktopTable(
                columns: const [
                  TableColumnSpec('name', 'Name', 150),
                  TableColumnSpec('hidden', 'Hidden', 100),
                  TableColumnSpec('value', 'Value', 200),
                ],
                layout: layout,
                rowCount: 1,
                cellBuilder: (_, i, key) => Text('$key-$i'),
              ),
            ),
          ),
        ),
      ),
    );
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    scroll.jumpTo(100);
    await tester.pump();
    final value = find.byKey(const ValueKey('column-value'));
    final rect = tester.getRect(value);
    // The whole header edge remains usable when text scaling increases height.
    final start = Offset(rect.right + 3, rect.bottom - 1);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(tester.getSize(value).width, 340);
    expect(scroll.offset, 100);
    expect(
      tester.getTopLeft(find.text('name-0')).dx,
      closeTo(rect.left + 340 + 8, 0.01),
    );
    // Reverse direction in the same gesture, then release and grab it again.
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(tester.getSize(value).width, 260);
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();
    final next = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('resize-value'))),
      kind: PointerDeviceKind.mouse,
    );
    await next.moveBy(const Offset(30, 0));
    await tester.pump();
    await next.up();
    await next.removePointer();
    await tester.pumpAndSettle();
    expect(tester.getSize(value).width, 290);
    expect(layout['order'], ['value', 'hidden', 'name']);
    expect(layout['hidden'], ['hidden']);
    expect((layout['widths'] as Map)['name'], 200);
    expect(tester.takeException(), isNull);
  });
}

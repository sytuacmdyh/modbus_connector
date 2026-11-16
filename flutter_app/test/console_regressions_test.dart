import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/main.dart';
import 'package:modbus_desktop/src/register_map.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/translations.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets('bus capture refreshes without another session or tab event', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = FakeBridge();
    final session = SessionController(bridge);
    await tester.pumpWidget(ModbusApp(controller: session));
    await tester.tap(find.text('Bus traffic'));
    await tester.pumpAndSettle();
    var sessionEvents = 0;
    session.addListener(() => sessionEvents++);
    bridge.onTraffic!(
      [
        {'time': 'live', 'direction': 'rx', 'hex': '01 03 AB CD'},
      ],
      {'operations': 3},
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('01 03 AB CD'), findsOneWidget);
    expect(find.textContaining('Operations 3'), findsOneWidget);
    // Packet updates must not rebuild the register map mid-acquisition cycle.
    expect(sessionEvents, 0);
    final list = find.byKey(const ValueKey('traffic-list'));
    for (var i = 0; i < 40; i++) {
      bridge.onTraffic!([
        {
          'time': '$i',
          'direction': 'rx',
          'hex': '01 03 ${i.toRadixString(16)}',
        },
      ], {});
    }
    await tester.pumpAndSettle();
    final scroll = tester.widget<ListView>(list).controller!;
    expect(scroll.position.extentAfter, lessThan(1));
    await tester.drag(list, const Offset(0, 100));
    await tester.pumpAndSettle();
    final offset = scroll.offset;
    expect(scroll.position.extentAfter, greaterThan(24));
    bridge.onTraffic!([
      {'time': 'newest', 'direction': 'rx', 'hex': '01 03 EF'},
    ], {});
    await tester.pumpAndSettle();
    expect(scroll.offset, offset);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets(
    'traffic tools share the title row and console height can be dragged',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SessionController(FakeBridge());
      await tester.pumpWidget(ModbusApp(controller: session));
      await tester.tap(find.text('Bus traffic'));
      await tester.pumpAndSettle();
      final title = tester.getRect(find.byType(TabBar));
      final copy = tester.getRect(find.byTooltip('Copy'));
      expect(copy.center.dy, title.center.dy);
      expect(copy.left, greaterThanOrEqualTo(title.right));
      addTearDown(() => appLanguage.value = 'en');
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final (language, scale, pixelRatio) in [
        ('en', 1.0, 1.0),
        ('zh_CN', 1.0, 1.5),
        ('zh_CN', 1.3, 1.5),
        ('en', 1.3, 1.0),
      ]) {
        appLanguage.value = language;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        tester.view.devicePixelRatio = pixelRatio;
        tester.view.physicalSize = Size(1280 * pixelRatio, 900 * pixelRatio);
        await tester.pumpAndSettle();
        for (final text in ['', '01 03']) {
          final filter = find.byKey(const ValueKey('traffic-hex-filter'));
          await tester.enterText(filter, text);
          await tester.pumpAndSettle();
          // Measure the painted border, not the TextField's larger hit-test box.
          final editor = tester.element(
            find.descendant(of: filter, matching: find.byType(EditableText)),
          );
          final border = InputDecorator.containerOf(editor)!;
          final borderRect = border.localToGlobal(Offset.zero) & border.size;
          final button = tester.getRect(find.byTooltip(tr('Copy')));
          expect(borderRect.center.dy, closeTo(button.center.dy, .5));
          expect(borderRect.height, 30);
          expect(tester.takeException(), isNull);
        }
      }
      appLanguage.value = 'en';
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      await tester.pumpAndSettle();
      final map = tester.getSize(find.byType(RegisterMapPanel));
      final console = find.byKey(const ValueKey('activity-console'));
      final before = tester.getSize(console).height;
      await tester.drag(
        find.byKey(const ValueKey('console-resize-handle')),
        const Offset(0, -100),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(console).height, closeTo(before + 100, 1));
      expect(
        tester.getSize(find.byType(RegisterMapPanel)).height,
        closeTo(map.height - 100, 1),
      );
      final expanded = tester.getSize(console).height;
      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      expect(tester.getSize(console).height, expanded);
      await tester.drag(
        find.byKey(const ValueKey('console-resize-handle')),
        const Offset(0, -2000),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(RegisterMapPanel)).height,
        greaterThan(120),
      );
      tester.view.physicalSize = const Size(900, 650);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byKey(const ValueKey('console-resize-handle')),
        const Offset(0, 2000),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(console).height, 180);
      await tester.tap(find.byTooltip('Hide console'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show console'));
      await tester.pumpAndSettle();
      expect(tester.getSize(console).height, 180);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}

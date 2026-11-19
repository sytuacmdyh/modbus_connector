import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/backend/catalog.dart';
import 'package:modbus_desktop/src/desktop_table.dart';
import 'package:modbus_desktop/src/register_map.dart';
import 'package:modbus_desktop/src/register_overview.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/translations.dart';

import 'fake_bridge.dart';

Map<String, dynamic> row(String name, int address, {bool writable = true}) => {
  'name': name,
  'address': address,
  'kind': 'holding_registers',
  'count': 1,
  'format': 'u16',
  'writable': writable,
};

Future<void> mount(WidgetTester tester, SessionController session) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await session.shutdown();
    session.dispose();
    appLanguage.value = 'en';
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: RegisterMapPanel(session: session)),
    ),
  );
  await tester.pumpAndSettle();
}

Finder inTable(String text) =>
    find.descendant(of: find.byType(DesktopTable), matching: find.text(text));

Future<void> choose(WidgetTester tester, String key, String label) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('templates without column preferences use essential columns', (
    tester,
  ) async {
    final session = SessionController(FakeBridge())
      ..restore(
        flutterState({
          'connection': {},
          'registers': [row('Fan', 0)],
        }),
      );
    await mount(tester, session);
    expect(inTable('Name'), findsOneWidget);
    expect(inTable('Engineering value'), findsOneWidget);
    expect(inTable('Data type'), findsNothing);
    expect(inTable('Raw HEX'), findsNothing);
    expect(inTable('Trend'), findsNothing);
  });

  testWidgets(
    'overview ignores writable filters and never acquires independently',
    (tester) async {
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      session.registers.addAll([
        row('Fan', 0),
        row('Temperature', 1, writable: false),
      ]);
      await session.connect({'timeout': .1}, 1);
      await session.registerMap.read();
      bridge.calls.clear();
      await mount(tester, session);
      expect(inTable('Fan'), findsOneWidget);
      expect(inTable('Temperature'), findsNothing);
      expect(find.byKey(const ValueKey('overview-value-1')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(RegisterOverview),
          matching: find.byType(Icon),
        ),
        findsNothing,
      );
      for (final key in [
        'map-filter-name',
        'map-filter-address',
        'map-filter-access',
        'map-filter-polling',
      ]) {
        expect(
          tester.getTopLeft(find.byKey(ValueKey(key))).dy,
          tester.getTopLeft(find.byKey(const ValueKey('map-filter-name'))).dy,
        );
      }
      await choose(tester, 'map-filter-access', 'Read-only');
      expect(inTable('Fan'), findsNothing);
      expect(inTable('Temperature'), findsOneWidget);
      expect(find.byKey(const ValueKey('overview-value-0')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.calls, isEmpty);
      expect(find.byKey(const ValueKey('map-filter-area')), findsNothing);
      expect(inTable('Raw HEX'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('map-columns')));
      await tester.pumpAndSettle();
      expect(find.text('Compact rows'), findsNothing);
      await tester.ensureVisible(find.text('Raw HEX'));
      await tester.tap(
        find.ancestor(
          of: find.text('Raw HEX'),
          matching: find.byType(CheckedPopupMenuItem<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(inTable('Raw HEX'), findsOneWidget);
    },
  );

  testWidgets(
    'dragging split persists and selection does not resize viewport',
    (tester) async {
      final session = SessionController(FakeBridge());
      session.registers.addAll([row('Fan', 0), row('Pump', 1)]);
      await mount(tester, session);
      final pane = find.byKey(const ValueKey('register-overview-pane'));
      final before = tester.getSize(pane).width;
      await tester.drag(
        find.byKey(const ValueKey('register-split-handle')),
        const Offset(100, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(pane).width, greaterThan(before + 70));
      expect(session.draft['map_split_ratio'], greaterThan(.47));
      final tableHeight = tester.getSize(find.byType(DesktopTable)).height;
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('map-selection-tools')), findsOneWidget);
      expect(tester.getSize(find.byType(DesktopTable)).height, tableHeight);
      final restored = SessionController(FakeBridge())
        ..restore(jsonDecode(jsonEncode(session.state())));
      expect(
        restored.draft['map_split_ratio'],
        session.draft['map_split_ratio'],
      );
      restored.dispose();
    },
  );

  testWidgets(
    'configuration cancels safely and colors survive template and row movement',
    (tester) async {
      final session = SessionController(FakeBridge());
      session.registers.addAll([row('Fan', 0), row('Pump', 1)]);
      session.registerResults.addAll([
        {
          'values': [120],
          'numeric': 120,
          'display': '120',
        },
        {
          'values': [5],
          'numeric': 5,
          'display': '5',
        },
      ]);
      await mount(tester, session);
      Future<void> configure() async {
        await tester.tap(find.byKey(const ValueKey('overview-configure')));
        await tester.pumpAndSettle();
      }

      await configure();
      await tester.tap(find.text('Clear selection'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(session.draft[overviewSettingsKey], isNull);
      expect(session.registers.first[overviewRowIdKey], isNull);
      await configure();
      await tester.tap(find.text('Clear selection'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('overview-select-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('overview-rules-0')));
      await tester.pumpAndSettle();
      expect(find.text('Log on entry'), findsNothing);
      await tester.tap(find.text('Add rule'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply').last);
      await tester.pumpAndSettle();
      // Selecting search matches must keep earlier selections and their color rules.
      await tester.enterText(
        find.descendant(
          of: find.byType(OverviewConfigDialog),
          matching: find.byType(TextField),
        ),
        'Pump',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all'));
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      final id = session.registers.first[overviewRowIdKey];
      expect(id, isA<String>());
      final items =
          session.draft[overviewSettingsKey]['blocks'][0]['items'] as List;
      expect(items, hasLength(2));
      expect(items.first['rules'], hasLength(1));
      Color? color() => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('overview-value-0')),
              matching: find.text('120'),
            ),
          )
          .style
          ?.color;
      expect(
        color(),
        Theme.of(tester.element(find.byType(RegisterOverview)))
            .colorScheme
            .error,
      );
      session.registers.setAll(0, session.registers.reversed.toList());
      session.registerResults.setAll(
        0,
        session.registerResults.reversed.toList(),
      );
      session.registerMap.stop();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('overview-value-1')),
          matching: find.text('120'),
        ),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('overview-template-');
        try {
          final catalog = NativeCatalog(directory: dir);
          final saved = await catalog.dispatch({
            'command': 'template_save',
            'name': 'Equipment',
            'state': session.state(),
          });
          final loaded = await catalog.dispatch({
            'command': 'template_load',
            'template_id': saved['id'],
          });
          final restored = SessionController(FakeBridge())
            ..restore(loaded['state']);
          expect(restored.registers[1][overviewRowIdKey], id);
          expect(
            restored.draft[overviewSettingsKey],
            session.draft[overviewSettingsKey],
          );
          restored.dispose();
        } finally {
          await dir.delete(recursive: true);
        }
      });
      expect(session.registers.first['alarms'], isNull);
      expect(session.logs, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'overview virtualizes thousands of registers and fits narrow translated layouts',
    (tester) async {
      final session = SessionController(FakeBridge());
      session.registers.addAll([
        for (var i = 0; i < 4096; i++) row('row$i', i),
      ]);
      await mount(tester, session);
      expect(find.text('row4095'), findsNothing);
      expect(find.byType(Text).evaluate().length, lessThan(300));
      final list = find.byKey(const ValueKey('register-overview-list'));
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)),
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('row4095'), findsOneWidget);
      appLanguage.value = 'zh_CN';
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.physicalSize = const Size(700, 650);
      await tester.pumpAndSettle();
      expect(find.text('配置显示'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/desktop_table.dart';
import 'package:modbus_desktop/src/expression_completion.dart';
import 'package:modbus_desktop/src/register_map.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/tool_widgets.dart';
import 'package:modbus_desktop/src/translations.dart';
import 'package:modbus_desktop/src/workbench.dart';
import 'package:modbus_desktop/src/workspace.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets(
    'column hiding/density persist, last column stays accessible and reset recovers all',
    (tester) async {
      final layout = <String, dynamic>{};
      Widget table() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: DesktopTable(
              columns: const [
                TableColumnSpec('name', 'Name', 150),
                TableColumnSpec('value', 'Value', 200),
              ],
              layout: layout,
              rowCount: 100,
              cellBuilder: (_, i, key) => Text('$key-$i'),
            ),
          ),
        ),
      );
      await tester.pumpWidget(table());
      await tester.tap(find.text('Name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Value').last);
      await tester.pumpAndSettle();
      expect(find.text('value-0'), findsNothing);
      expect(layout['hidden'], ['value']);
      await tester.tap(find.text('Name'));
      await tester.pumpAndSettle();
      final last = tester.widget<CheckedPopupMenuItem<String>>(
        find.ancestor(
          of: find.text('Name').last,
          matching: find.byType(CheckedPopupMenuItem<String>),
        ),
      );
      expect(last.enabled, isFalse);
      await tester.tap(find.text('Compact rows'));
      await tester.pumpAndSettle();
      expect(layout['compact'], isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(table());
      expect(find.text('value-0'), findsNothing);
      await tester.tap(find.text('Name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset columns'));
      await tester.pumpAndSettle();
      expect(find.text('value-0'), findsOneWidget);
      expect(layout, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'completion matches reference/function prefixes and preserves suffixes',
    () {
      final names = ['Temperature', 'Pressure'];
      final ref = expressionCompletions(
        const TextEditingValue(
          text: '2 + [te] * 3',
          selection: TextSelection.collapsed(offset: 7),
        ),
        names,
      );
      expect(ref.words, ['Temperature]']);
      expect(
        '2 + [te] * 3'.replaceRange(ref.start, ref.end, ref.words.single),
        '2 + [Temperature] * 3',
      );
      final fn = expressionCompletions(
        const TextEditingValue(
          text: '2 + sq(4)',
          selection: TextSelection.collapsed(offset: 6),
        ),
        names,
      );
      expect(fn.words, ['sqrt(']);
      expect(
        '2 + sq(4)'.replaceRange(fn.start, fn.end, fn.words.single),
        '2 + sqrt(4)',
      );
      expect(
        expressionCompletions(
          const TextEditingValue(
            text: 'prev',
            selection: TextSelection.collapsed(offset: 4),
          ),
          names,
        ).words,
        isEmpty,
      );
      expect(
        expressionCompletions(
          const TextEditingValue(
            text: 'xyz',
            selection: TextSelection.collapsed(offset: 3),
          ),
          names,
        ).words,
        isEmpty,
      );
    },
  );

  testWidgets('completion Enter inserts, Escape dismisses suggestions only', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await expressionPrompt(
                context,
                value: '',
                names: ['Temperature'],
              );
            },
            child: const Text('edit'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('edit'));
    await tester.pumpAndSettle();
    final input = find.byType(TextField);
    await tester.enterText(input, '[te');
    await tester.pump();
    expect(find.text('Temperature]'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '[Temperature]');
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(input, 'sq');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('sqrt('), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(input, 'ra');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, 'randint(');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(result, 'randint(');
  });

  testWidgets(
    'table resizes/reorders columns, virtualizes and restores layout',
    (tester) async {
      final layout = <String, dynamic>{};
      Widget table() => MaterialApp(
        home: Scaffold(
          body: DesktopTable(
            columns: const [
              TableColumnSpec('name', 'Name', 150),
              TableColumnSpec('address', 'Address', 120),
              TableColumnSpec('value', 'Value', 200),
            ],
            layout: layout,
            rowCount: 512,
            cellBuilder: (_, i, key) => Text('$key-$i'),
          ),
        ),
      );
      await tester.pumpWidget(table());
      expect(find.text('name-511'), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('resize-name')),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();
      expect((layout['widths'] as Map)['name'], greaterThan(180));
      await tester.dragFrom(
        tester.getCenter(find.text('Name')),
        tester.getCenter(find.text('Value')) -
            tester.getCenter(find.text('Name')),
      );
      await tester.pumpAndSettle();
      expect(layout['order'], ['address', 'value', 'name']);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(table());
      expect(
        tester.getTopLeft(find.text('Address')).dx,
        lessThan(tester.getTopLeft(find.text('Name')).dx),
      );
      await tester.tap(find.text('Name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset columns'));
      await tester.pumpAndSettle();
      expect(layout, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'invalid persisted table widths/order recover and layouts round trip',
    () {
      final session = SessionController(FakeBridge());
      session.draft['map_table'] = {
        'order': ['value', 'name'],
        'widths': {'name': 222},
      };
      final restored = SessionController(FakeBridge())
        ..restore(session.state());
      expect(desktopTableLayout(restored.draft, 'map_table')['order'], [
        'value',
        'name',
      ]);
      restored.draft['map_table'] = 'bad';
      expect(desktopTableLayout(restored.draft, 'map_table'), isEmpty);
      session.dispose();
      restored.dispose();
    },
  );

  testWidgets(
    'register map fills available space and virtualizes rows without a dialog',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SessionController(FakeBridge());
      session.registers.add({
        'name': 'Embedded',
        'kind': 'holding_registers',
        'address': 5,
        'count': 1,
        'format': 'dec',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Workbench(
            controller: session,
            themeMode: ThemeMode.system,
            onThemeChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(RegisterMapPanel), findsOneWidget);
      expect(find.text('Embedded').hitTestable(), findsOneWidget);
      final shortHeight = tester.getSize(find.byType(DesktopTable)).height;
      expect(shortHeight, greaterThan(250));
      await tester.tap(find.text('Add row'));
      await tester.pumpAndSettle();
      expect(find.byType(RegisterRowDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      session.registers.addAll([
        for (var i = 1; i < 512; i++)
          {
            'name': 'row$i',
            'kind': 'holding_registers',
            'address': i,
            'count': 1,
            'format': 'dec',
          },
      ]);
      session.registerMap.changed();
      await tester.pumpAndSettle();
      final largeHeight = tester.getSize(find.byType(DesktopTable)).height;
      expect(largeHeight, shortHeight);
      expect(find.text('row511'), findsNothing);
      final rows = find.descendant(
        of: find.byType(DesktopTable),
        matching: find.byType(ListView),
      );
      tester
          .widget<ListView>(rows)
          .controller!
          .jumpTo(
            tester.widget<ListView>(rows).controller!.position.maxScrollExtent,
          );
      await tester.pumpAndSettle();
      expect(find.text('row511'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('narrow saved action column and larger text remain usable', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final session = SessionController(FakeBridge());
    session.draft['map_table'] = {
      'order': ['actions', 'name'],
      'widths': {'actions': 64, 'name': -999},
    };
    session.registers.add({
      'name': 'State',
      'kind': 'holding_registers',
      'address': 0,
      'count': 1,
      'format': 'dec',
      'value_names': {'0': 'Off', '1': 'On'},
    });
    await tester.pumpWidget(
      MaterialApp(home: RegisterMapDialog(session: session)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButton<int>), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('embedded map fits minimum window with Chinese and larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 650);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    appLanguage.value = 'zh_CN';
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      appLanguage.value = 'en';
    });
    final session = SessionController(FakeBridge());
    await tester.pumpWidget(
      MaterialApp(
        home: Workbench(
          controller: session,
          themeMode: ThemeMode.system,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RegisterMapPanel), findsOneWidget);
    expect(find.text(tr('Add row')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets(
    'Settings consolidates language appearance and workspace preferences',
    (tester) async {
      final workspace = WorkspaceController(bridgeFactory: FakeBridge.new);
      addTearDown(() {
        appLanguage.value = 'en';
        appTheme.value = ThemeMode.system;
        workspace.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SessionWorkspace(
            controller: workspace,
            themeMode: ThemeMode.system,
            onThemeChanged: (v) => appTheme.value = v,
          ),
        ),
      );
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Automatically save workspace'), findsOneWidget);
      expect(find.text('Export workspace'), findsOneWidget);
      await tester.tap(find.text('system'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('dark').last);
      await tester.pumpAndSettle();
      expect(appTheme.value, ThemeMode.dark);
      await tester.tap(find.text('Check for updates on startup'));
      await tester.pump();
      expect(workspace.exportState()['auto_check_updates'], isFalse);
      await tester.tap(find.text('Automatically save workspace'));
      await tester.pump();
      expect(workspace.exportState()['autosave'], isFalse);
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('简体中文').last);
      await tester.pumpAndSettle();
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('自动保存工作区'), findsOneWidget);
      expect(find.text('启动时自动检查更新'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

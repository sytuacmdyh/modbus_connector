import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/desktop_table.dart';
import 'package:modbus_desktop/src/register_map.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

class MapBridge extends FakeBridge {
  Completer<BridgeReply>? held;
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    if (command['command'] == 'read_rows') {
      calls.add(command);
      return held?.future ??
          Future.value(
            BridgeReply({
              'rows': [
                {
                  'values': [value],
                  'display': '$value',
                  'numeric': value,
                  'alarm': null,
                },
              ],
            }, true),
          );
    }
    return super.request(command, timeout: timeout);
  }
}

class ExpressionMapBridge extends MapBridge {
  final evaluation = Completer<BridgeReply>();
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) {
    if (command['command'] == 'evaluate_expressions') return evaluation.future;
    return super.request(command, timeout: timeout);
  }
}

void main() {
  test(
    'read-only rows block every write path and survive workspace restore',
    () async {
      final bridge = MapBridge();
      final session = SessionController(bridge);
      addTearDown(session.dispose);
      session.restore({
        'registers': [
          {
            'name': 'temperature',
            'kind': 'holding_registers',
            'address': 0,
            'count': 1,
            'writable': false,
          },
        ],
      });
      expect(session.state()['registers'][0]['writable'], false);
      await session.connect({'timeout': 0.1}, 1);
      await session.registerMap.read();
      expect(session.registerResults.single['values'], [100]);
      bridge.calls.clear();
      await session.registerMap.writeRow(0, values: [42]);
      await session.registerMap.writeRow(0, text: '42');
      for (final action in [
        'zero',
        'one',
        'increment',
        'decrement',
        'toggle',
      ]) {
        await session.registerMap.quickValue(0, action);
      }
      expect(bridge.calls, isEmpty);
      await session.disconnect();
      expect(
        () => session.restore({
          'registers': [
            {
              'kind': 'holding_registers',
              'address': 1,
              'count': 1,
              'writable': 'false',
            },
          ],
        }),
        throwsFormatException,
      );
    },
  );

  test('a queued write rechecks permission after the active read', () async {
    final bridge = MapBridge();
    final session = SessionController(bridge);
    addTearDown(session.dispose);
    session.registers.add({
      'kind': 'holding_registers',
      'address': 0,
      'count': 1,
      'writable': true,
    });
    await session.connect({'timeout': 0.1}, 1);
    bridge.held = Completer<BridgeReply>();
    session.registerMap.start(5000);
    await Future<void>.delayed(Duration.zero);
    final write = session.registerMap.writeRow(0, values: [42]);
    session.registers.single['writable'] = false;
    bridge.held!.complete(
      const BridgeReply({
        'rows': [
          {
            'values': [100],
            'display': '100',
            'numeric': 100,
          },
        ],
      }, true),
    );
    await write;
    session.registerMap.stop();
    expect(bridge.calls.where((c) => c['command'] == 'write_row'), isEmpty);
  });

  testWidgets('read-only map disables numeric, enum, bit and menu writes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = MapBridge();
    final session = SessionController(bridge);
    addTearDown(session.dispose);
    session.registers.addAll([
      for (var i = 0; i < 3; i++)
        {
          'name': 'readonly $i',
          'kind': 'holding_registers',
          'address': i,
          'count': 1,
          'format': 'u16',
          'writable': false,
          if (i == 1) 'value_names': {'0': 'Off', '1': 'On'},
          if (i == 2) 'bitmask': true,
        },
    ]);
    await session.connect({'timeout': 0.1}, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RegisterMapPanel(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.lock_outline), findsNWidgets(3));
    for (final button in tester.widgetList<IconButton>(
      find.byType(IconButton),
    )) {
      if (['Register row is read-only', 'Edit bits'].contains(button.tooltip)) {
        expect(button.onPressed, isNull);
      }
    }
    expect(
      tester
          .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
          .onChanged,
      isNull,
    );
    await tester.tap(find.text('readonly 0'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    for (final label in [
      'Write 0',
      'Write 1',
      'Increment',
      'Decrement',
      'Toggle',
    ]) {
      final item = tester.widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      expect(item.enabled, false);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(bridge.calls.where((c) => c['command'] == 'write_row'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'row editor saves permission and fixes input areas to read-only',
    (tester) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => const RegisterRowDialog(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Allow writes'));
      await tester.tap(find.text('Allow writes'));
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(saved!['writable'], false);
      await tester.pumpWidget(
        const MaterialApp(
          home: RegisterRowDialog(
            row: {'kind': 'input_registers', 'address': 0, 'count': 1},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final permission = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, 'Allow writes'),
      );
      expect(permission.value, false);
      expect(permission.onChanged, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('Edit bits requires a single bitmask u16 holding row', () {
    Map<String, dynamic> row({
      String kind = 'holding_registers',
      int count = 1,
      String format = 'u16',
      bool bitmask = true,
    }) => {'kind': kind, 'count': count, 'format': format, 'bitmask': bitmask};
    expect(canEditBits(row()), isTrue);
    expect(canEditBits(row(format: 'dec')), isTrue);
    expect(canEditBits(row(bitmask: false)), isFalse);
    expect(canEditBits(row(format: 's16')), isFalse);
    expect(canEditBits(row(count: 2)), isFalse);
    expect(canEditBits(row(kind: 'input_registers')), isFalse);
  });

  testWidgets('read progress does not shift the table under the pointer', (
    tester,
  ) async {
    final bridge = MapBridge();
    final session = SessionController(bridge);
    await session.connect({'timeout': 0.1}, 1);
    session.registers.add({
      'name': 'x',
      'kind': 'holding_registers',
      'address': 0,
      'count': 1,
    });
    await tester.pumpWidget(
      MaterialApp(home: RegisterMapDialog(session: session)),
    );
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.byType(DesktopTable));
    bridge.held = Completer<BridgeReply>();
    final reading = session.registerMap.read();
    await tester.pump();
    expect(tester.getTopLeft(find.byType(DesktopTable)), before);
    bridge.held!.complete(
      const BridgeReply({
        'rows': [
          {
            'values': [1],
            'numeric': 1,
            'display': '1',
          },
        ],
      }, true),
    );
    await reading;
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(DesktopTable)), before);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('polling hides progress and keeps value writes enabled', (
    tester,
  ) async {
    final bridge = MapBridge();
    final session = SessionController(bridge);
    await session.connect({'timeout': 0.1}, 1);
    session.registers.add({
      'name': 'x',
      'kind': 'holding_registers',
      'address': 0,
      'count': 1,
    });
    await tester.pumpWidget(
      MaterialApp(home: RegisterMapDialog(session: session)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Start polling'), findsOneWidget);
    bridge.held = Completer<BridgeReply>();
    session.registerMap.start(100);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    final write = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Write row'),
        matching: find.byType(IconButton),
      ),
    );
    expect(write.onPressed, isNotNull);
    session.registerMap.stop();
    bridge.held!.complete(const BridgeReply({'rows': []}, true));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('poll cycle keeps toolbar and row enabled states stable', (
    tester,
  ) async {
    final bridge = MapBridge();
    final session = SessionController(bridge);
    await session.connect({'timeout': 0.1}, 1);
    session.registers.add({
      'name': 'x',
      'kind': 'holding_registers',
      'address': 0,
      'count': 1,
    });
    await tester.pumpWidget(
      MaterialApp(home: RegisterMapDialog(session: session)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('More tools'));
    await tester.pumpAndSettle();
    final held = bridge.held = Completer<BridgeReply>();
    session.registerMap.start(5000);
    await tester.pump();
    List<bool> enabled() => [
      tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Read map'),
              )
              .onPressed !=
          null,
      tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Add row'),
              )
              .onPressed !=
          null,
      tester.widget<DesktopTable>(find.byType(DesktopTable)).onRowTap != null,
      tester
          .widget<PopupMenuButton<String>>(
            find.ancestor(
              of: find.byTooltip('CSV'),
              matching: find.byType(PopupMenuButton<String>),
            ),
          )
          .enabled,
    ];
    final during = enabled();
    held.complete(
      const BridgeReply({
        'rows': [
          {
            'values': [1],
            'display': '1',
            'numeric': 1,
          },
        ],
      }, true),
    );
    await tester.pump();
    expect(session.registerMap.reading, isFalse);
    expect(enabled(), during);
    session.registerMap.stop();
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets(
    'value changes highlight only that cell and expire after three seconds',
    (tester) async {
      final bridge = MapBridge();
      final session = SessionController(bridge);
      await session.connect({'timeout': 0.1}, 1);
      session.registers.add({
        'name': 'x',
        'kind': 'holding_registers',
        'address': 0,
        'count': 1,
      });
      session.registers.add({
        ...session.registers.single,
        'address': 1,
        'name': 'y',
      });
      await tester.pumpWidget(
        MaterialApp(home: RegisterMapDialog(session: session)),
      );
      await session.registerMap.read();
      await tester.pump();
      Color? color() => tester
          .widget<Container>(find.byKey(const ValueKey('map-value-0')))
          .color;
      expect(color(), isNull);
      bridge.value = 101;
      await session.registerMap.read(onlyIndices: {0});
      await tester.pump();
      expect(color(), isNotNull);
      expect(
        tester
            .widget<Container>(find.byKey(const ValueKey('map-value-1')))
            .color,
        isNull,
      );
      await tester.pump(const Duration(seconds: 2));
      await session.registerMap.read(onlyIndices: {0});
      await tester.pump();
      expect(color(), isNotNull);
      await tester.pump(const Duration(milliseconds: 1001));
      expect(color(), isNull);
      bridge.value = 102;
      await session.registerMap.read(onlyIndices: {0});
      await tester.pump();
      expect(color(), isNotNull);
      await tester.pump(const Duration(seconds: 2));
      bridge.value = 103;
      await session.registerMap.read(onlyIndices: {0});
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(color(), isNotNull);
      await tester.pump(const Duration(milliseconds: 1001));
      expect(color(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  test(
    'large map publishes a bounded number of UI updates per read cycle',
    () async {
      final bridge = MapBridge();
      final session = SessionController(bridge);
      await session.connect({'timeout': 0.1}, 1);
      session.registers.addAll(
        List.generate(
          248,
          (i) => <String, dynamic>{
            'name': 'row $i',
            'kind': 'holding_registers',
            'address': i,
            'count': 1,
          },
        ),
      );
      var updates = 0;
      session.addListener(() => updates++);
      await session.registerMap.read();
      expect(session.registerResults, hasLength(248));
      expect(session.histories, isEmpty);
      expect(
        bridge.calls.where((c) => c['command'] == 'read_rows'),
        hasLength(248),
      );
      expect(updates, lessThanOrEqualTo(6));
      session.dispose();
    },
  );

  test('quick value actions use raw first words, clamp and reject read-only/missing values', () async {
    final bridge = MapBridge();
    final session = SessionController(bridge);
    await session.connect({'timeout': 0.1}, 7);
    session.registers.add({
      'kind': 'holding_registers',
      'address': 20,
      'count': 2,
      'scale': 10,
      'unit_id': 9,
    });
    await session.registerMap.quickValue(0, 'increment');
    expect(bridge.calls.where((c) => c['command'] == 'write_row'), isEmpty);
    session.registerResults.add({
      'values': [65535, 123],
      'display': '655350',
    });
    await session.registerMap.quickValue(0, 'increment');
    final write = bridge.calls.firstWhere((c) => c['command'] == 'write_row');
    expect(write['values'], [65535]);
    expect(write['unit'], 7);
    expect(write['row']['unit_id'], 9);
    expect(write['row']['address'], 20);
    bridge.calls.clear();
    session.registers[0]['kind'] = 'input_registers';
    await session.registerMap.quickValue(0, 'zero');
    expect(bridge.calls, isEmpty);
    session.registerResults[0] = {
      'values': [1],
    };
    session.registers[0]['kind'] = 'holding_registers';
    await session.registerMap.quickValue(0, 'toggle');
    expect(
      bridge.calls.firstWhere((c) => c['command'] == 'write_row')['values'],
      [0],
    );
    await session.disconnect();
    bridge.calls.clear();
    await session.registerMap.quickValue(0, 'one');
    expect(bridge.calls, isEmpty);
    session.dispose();
  });

  test('stopping map suppresses late expression evaluation failures', () async {
    final bridge = ExpressionMapBridge();
    final session = SessionController(bridge);
    await session.connect({'timeout': 0.1}, 1);
    session.registers.add({'name': 'x', 'address': 0});
    session.expressions.add({'name': 'fx', 'text': '[x]*2'});
    final reading = session.registerMap.read();
    await Future<void>.delayed(Duration.zero);
    session.registerMap.stop();
    bridge.evaluation.completeError(
      const BridgeException('late expression error'),
    );
    await reading;
    expect(session.error, isNull);
    expect(session.expressionResults, isEmpty);
    expect(
      session.logs.where((l) => l.message.contains('late expression error')),
      isEmpty,
    );
    session.dispose();
  });

  testWidgets(
    'inline enum writes raw values without applying engineering scale',
    (tester) async {
      final bridge = MapBridge();
      final session = SessionController(bridge);
      await session.connect({'timeout': 0.1}, 1);
      session.registers.add({
        'name': 'State',
        'kind': 'holding_registers',
        'address': 0,
        'count': 1,
        'format': 'dec',
        'scale': 10,
        'value_names': {'0': 'Off', '1': 'On'},
      });
      await tester.pumpWidget(
        MaterialApp(home: RegisterMapDialog(session: session)),
      );
      await tester.ensureVisible(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 = On').last);
      await tester.pumpAndSettle();
      expect(
        bridge.calls.firstWhere((c) => c['command'] == 'write_row')['values'],
        [1],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  for (final platform in [TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets(
      'map shortcuts select duplicate move and delete rows on $platform',
      (tester) async {
        final session = SessionController(MapBridge());
        session.registers.addAll([
          for (var i = 0; i < 2; i++)
            {
              'name': 'row$i',
              'kind': 'holding_registers',
              'address': i,
              'count': 1,
              'format': 'dec',
            },
        ]);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: RegisterMapDialog(session: session),
          ),
        );
        await tester.pump();
        final modifier = platform == TargetPlatform.macOS
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
        await tester.tap(find.byTooltip('Selected rows'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Duplicate selected rows'));
        await tester.pumpAndSettle();
        expect(session.registers.length, 4);
        expect(session.registers.last['name'], 'row1 copy');
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pump();
        expect(session.registers.map((r) => r['name']), [
          'row0 copy',
          'row1 copy',
        ]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }

  testWidgets(
    'session map keeps polling after dialog closes, stops on disconnect',
    (tester) async {
      final bridge = MapBridge();
      final session = SessionController(
        bridge,
        clock: () => tester.binding.clock.now(),
      );
      session.registers.add({
        'name': 'X',
        'kind': 'holding_registers',
        'address': 0,
        'count': 1,
        'format': 'dec',
      });
      await session.connect({'timeout': 0.1}, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => RegisterMapDialog(session: session),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start polling'));
      await tester.pump();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      final count = bridge.calls.length;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(session.registerMap.polling, isTrue);
      expect(bridge.calls.length, greaterThan(count));
      await session.disconnect();
      expect(session.registerMap.polling, isFalse);
      final stopped = bridge.calls.length;
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.calls.length, stopped);
      session.dispose();
    },
  );

  test(
    'map cancellation suppresses stale data and raw snapshots detect changes',
    () async {
      final bridge = MapBridge();
      final session = SessionController(bridge);
      session.registers.add({'name': 'X', 'address': 0});
      await session.connect({'timeout': 0.1}, 1);
      final model = RegisterMapController(session);
      await model.read();
      model.capture('before');
      expect(model.diff('before'), isEmpty);
      bridge.value = 42;
      await model.read();
      expect(model.diff('before').single, contains('100'));
      bridge.held = Completer<BridgeReply>();
      final reading = model.read();
      model.stop();
      bridge.held!.complete(
        const BridgeReply({
          'rows': [
            {
              'values': [99],
            },
          ],
        }, true),
      );
      await reading;
      expect(model.results.single['values'], [42]);
      model.dispose();
      session.dispose();
    },
  );
  test('stopped map discards late alarm/error side effects and removed snapshots stay visible', () async {
    final bridge = MapBridge();
    final session = SessionController(bridge);
    session.registers.add({
      'name': 'X',
      'kind': 'holding_registers',
      'address': 0,
      'count': 1,
    });
    await session.connect({'timeout': 0.1}, 1);
    final model = RegisterMapController(session);
    await model.read();
    model.capture('old');
    bridge.held = Completer<BridgeReply>();
    final reading = model.read();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.calls.last['command'], 'read_rows');
    model.stop();
    bridge.held!.completeError(const BridgeException('late error'));
    await reading;
    expect(session.error, isNull);
    expect(
      session.logs.where((l) => l.message.contains('late error')),
      isEmpty,
    );
    session.registers.clear();
    expect(model.diff('old').single, contains('(removed)'));
    model.dispose();
    session.dispose();
  });
  test(
    'map scheduler skips disabled rows and ignores legacy per-row intervals',
    () async {
      var now = DateTime(2026);
      final bridge = MapBridge();
      final session = SessionController(bridge);
      await session.connect({'timeout': 0.1}, 1);
      session.registers.addAll([
        {
          'name': 'fast',
          'kind': 'holding_registers',
          'address': 0,
          'count': 1,
          'poll_ms': 100,
        },
        {
          'name': 'slow',
          'kind': 'holding_registers',
          'address': 1,
          'count': 1,
          'poll_ms': 1000,
        },
        {
          'name': 'disabled',
          'kind': 'holding_registers',
          'address': 2,
          'count': 1,
          'poll_enabled': false,
        },
      ]);
      final model = RegisterMapController(session, clock: () => now);
      await model.read(dueOnly: true);
      expect(bridge.calls.where((c) => c['command'] == 'read_rows').length, 2);
      now = now.add(const Duration(milliseconds: 200));
      await model.read(dueOnly: true);
      expect(bridge.calls.where((c) => c['command'] == 'read_rows').length, 2);
      now = now.add(const Duration(milliseconds: 800));
      await model.read(dueOnly: true);
      expect(bridge.calls.where((c) => c['command'] == 'read_rows').length, 4);
      expect(session.registerResults.last['values'], isNull);
      model.dispose();
      session.dispose();
    },
  );
  testWidgets(
    'row editor validates width and bits editor toggles all 16 bits',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: RegisterRowDialog()));
      await tester.enterText(
        find.widgetWithText(TextField, 'address'),
        '65536',
      );
      await tester.tap(find.text('Apply'));
      await tester.pump();
      expect(find.textContaining('Check address/count'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const BitsDialog(value: 0),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('b0 '));
      await tester.pump();
      expect(find.text('Bits · 0x0001'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

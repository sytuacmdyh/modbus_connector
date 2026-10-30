import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/desktop_table.dart';
import 'package:modbus_desktop/src/workspace.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets(
    'local demo keeps row selection visible on the left while polling',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = WorkspaceController(bridgeFactory: FakeBridge.new);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: SessionWorkspace(
              controller: workspace,
              themeMode: ThemeMode.light,
              onThemeChanged: (_) {},
            ),
          ),
        );
        await workspace.openDemo();
        await tester.pump(const Duration(milliseconds: 100));
        final demo = workspace.sessions.last;
        expect(demo.registerMap.polling, isTrue);
        final selectHeader = find.byKey(const ValueKey('column-select'));
        expect(selectHeader, findsOneWidget);
        expect(
          tester.getTopLeft(selectHeader).dx,
          lessThan(
            tester.getTopLeft(find.byKey(const ValueKey('column-name'))).dx,
          ),
        );
        final checkbox = find
            .descendant(
              of: find.byType(DesktopTable),
              matching: find.byType(Checkbox),
            )
            .hitTestable()
            .first;
        expect(tester.widget<Checkbox>(checkbox).onChanged, isNotNull);
        await tester.tap(checkbox);
        await tester.pump();
        expect(tester.widget<Checkbox>(checkbox).value, isTrue);
        expect(
          find.byKey(const ValueKey('map-selection-tools')),
          findsOneWidget,
        );
        expect(demo.registerMap.polling, isTrue);
      } finally {
        await workspace.shutdown();
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
      }
    },
  );

  testWidgets('background reads keep running without animating hidden tabs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final workspace = WorkspaceController(bridgeFactory: FakeBridge.new);
    final session = workspace.sessions.first;
    await session.connect({'transport': 'demo', 'timeout': 0.1}, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: SessionWorkspace(
          controller: workspace,
          themeMode: ThemeMode.light,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bridge = session.bridge as FakeBridge;
    bridge.heldRead = Completer<BridgeReply>();
    final reading = session.registerMap.read();
    await tester.pump();
    expect(session.registerMap.reading, isTrue);
    workspace.add();
    await tester.pumpAndSettle();
    expect(session.registerMap.reading, isTrue);
    expect(tester.binding.transientCallbackCount, 0);
    session.registerMap.stop();
    bridge.heldRead!.complete(
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
    await workspace.shutdown();
    await tester.pumpWidget(const SizedBox());
    workspace.dispose();
  });

  testWidgets('demo connection choice preserves the original form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final workspace = WorkspaceController(bridgeFactory: FakeBridge.new);
    await tester.pumpWidget(
      MaterialApp(
        home: SessionWorkspace(
          controller: workspace,
          themeMode: ThemeMode.system,
          onThemeChanged: (_) {},
        ),
      ),
    );
    final original = workspace.sessions.first;
    await tester.tap(find.text('Connection settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Serial RTU'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local demo').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(workspace.sessions, hasLength(2));
    expect(workspace.sessions.last.registerMap.polling, isTrue);
    workspace.select(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connection settings'));
    await tester.pumpAndSettle();
    final field = tester.widget<DropdownButtonFormField<String>>(
      find.widgetWithText(DropdownButtonFormField<String>, 'Transport'),
    );
    final state = tester.state<FormFieldState<String>>(find.byWidget(field));
    expect(state.value, 'rtu');
    expect(original.connectionConfig['transport'], isNot('demo'));
    await workspace.shutdown();
    await tester.pumpWidget(const SizedBox());
    workspace.dispose();
  });

  testWidgets('demo gets an isolated tab and stops with its owned session', (
    tester,
  ) async {
    final workspace = WorkspaceController(bridgeFactory: FakeBridge.new);
    final original = workspace.sessions.first;
    original.draft['transport'] = 'rtu';
    original.registers.add({
      'name': 'Device',
      'kind': 'holding_registers',
      'address': 500,
      'count': 1,
    });
    await workspace.openDemo();
    await tester.pump();
    final demo = workspace.sessions.last;
    expect(workspace.selected, 1);
    expect(demo.connected, isTrue);
    expect(demo.registerMap.polling, isTrue);
    expect(demo.registers, hasLength(6));
    expect(original.registers.single['address'], 500);
    expect(original.draft['transport'], 'rtu');
    expect(original.connected, isFalse);
    await workspace.remove(demo);
    expect(demo.registerMap.polling, isFalse);
    expect((demo.bridge as FakeBridge).closed, isTrue);
    expect(workspace.sessions.single, same(original));
    await workspace.shutdown();
    workspace.dispose();
  });

  test('closing a demo during connection cannot start its poller', () async {
    final pending = Completer<BridgeReply>();
    var created = 0;
    final workspace = WorkspaceController(
      bridgeFactory: () {
        final bridge = FakeBridge();
        if (++created == 2) bridge.heldConnect = pending;
        return bridge;
      },
    );
    final opening = workspace.openDemo();
    final demo = workspace.sessions.last;
    final closing = workspace.remove(demo);
    pending.complete(const BridgeReply({'description': 'demo'}, true));
    await opening;
    await closing;
    expect(demo.connected, isFalse);
    expect(demo.registerMap.polling, isFalse);
    expect(workspace.sessions, hasLength(1));
    await workspace.shutdown();
    workspace.dispose();
  });

  test(
    'tabs own independent connections and closing waits for active I/O',
    () async {
      final workspace = WorkspaceController(bridgeFactory: FakeBridge.new);
      final first = workspace.sessions.first;
      workspace.add();
      final second = workspace.sessions.last;
      await first.connect({'transport': 'demo', 'timeout': 0.1}, 1);
      await second.connect({'transport': 'demo', 'timeout': 0.1}, 2);
      final bridge = first.bridge as FakeBridge;
      bridge.heldRead = Completer<BridgeReply>();
      final reading = first.registerMap.read();
      final closing = workspace.remove(first);
      expect(bridge.closed, isFalse);
      await second.registerMap.read();
      expect(second.registerResults, isNotEmpty);
      bridge.heldRead!.complete(
        const BridgeReply({
          'rows': [
            {
              'values': [1],
              'numeric': 1,
            },
          ],
        }, true),
      );
      await reading;
      await closing;
      expect(first.registerResults, isEmpty);
      expect(bridge.closed, isTrue);
      expect(second.connected, isTrue);
      expect(workspace.selected, 0);
      await workspace.shutdown();
      workspace.dispose();
    },
  );
}

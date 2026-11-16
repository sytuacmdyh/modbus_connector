import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/main.dart';
import 'package:modbus_desktop/src/register_map.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/traffic_panel.dart';
import 'package:modbus_desktop/src/translations.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets(
    'console tabs preserve capture controls without resizing the map',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      final root = Directory.systemTemp.createTempSync('traffic-export-');
      const fileChannel = MethodChannel('plugins.flutter.io/file_selector');
      String? copied;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
        fileChannel,
        (_) async => '${root.path}/traffic.txt',
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        messenger.setMockMethodCallHandler(fileChannel, null);
        root.deleteSync(recursive: true);
      });
      await tester.pumpWidget(ModbusApp(controller: session));
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabs.tabs.map((tab) => ((tab as Tab).child as LText).data), [
        'Activity',
        'Bus traffic',
      ]);
      expect(
        find.text('Connection and error events appear here'),
        findsOneWidget,
      );
      bridge.onTraffic!(
        [
          {'time': 't1', 'direction': 'tx', 'hex': '01 03 AA'},
          {'time': 't2', 'direction': 'rx', 'hex': '01 03 BB'},
        ],
        {
          'operations': 20,
          'tx_bytes': 3,
          'rx_bytes': 3,
          'errors': 1,
          'average_ms': 12.3,
        },
      );
      final mapRect = tester.getRect(find.byType(RegisterMapPanel));
      await tester.tap(find.text('Bus traffic'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.getRect(find.byType(RegisterMapPanel)), mapRect);
      expect(find.textContaining('Operations 20'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(TrafficPanel),
          matching: find.textContaining('Errors 1'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(TrafficPanel),
          matching: find.textContaining('Average 12.3 ms'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('traffic-direction')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('RX').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('traffic-hex-filter')),
        'BB',
      );
      await tester.tap(find.byTooltip('Pause display'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      bridge.onTraffic!([
        {'time': 't3', 'direction': 'rx', 'hex': '01 03 CC'},
      ], {});
      await tester.pump();
      await tester.tap(find.text('Bus traffic'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Resume display'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide console'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show console'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Resume display'), findsOneWidget);
      expect(find.textContaining('t2  RX  01 03 BB'), findsOneWidget);
      expect(find.textContaining('01 03 CC'), findsNothing);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const ValueKey('traffic-hex-filter')),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        'BB',
      );
      expect(tester.getRect(find.byType(RegisterMapPanel)), mapRect);
      await tester.tap(find.byTooltip('Copy'));
      await tester.pumpAndSettle();
      expect(copied, 't2  rx  01 03 BB');
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Export traffic log'));
        final file = File('${root.path}/traffic.txt');
        // The export callback flushes asynchronously after the chooser completes.
        for (var i = 0; i < 100; i++) {
          if (await file.exists() && await file.readAsString() == copied) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(await file.readAsString(), copied);
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Resume display'));
      await tester.enterText(
        find.byKey(const ValueKey('traffic-hex-filter')),
        '',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('01 03 CC'), findsOneWidget);
      expect(find.textContaining('01 03 AA'), findsNothing);
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(session.traffic, isEmpty);
      expect(find.textContaining('01 03 CC'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('traffic tab expands the short-window console with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 650);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final session = SessionController(FakeBridge());
    await tester.pumpWidget(ModbusApp(controller: session));
    expect(find.byKey(const ValueKey('traffic-list')), findsNothing);
    await tester.tap(find.text('Bus traffic'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('traffic-list')), findsOneWidget);
    expect(find.byTooltip('Hide console'), findsOneWidget);
    final mapRect = tester.getRect(find.byType(RegisterMapPanel));
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(RegisterMapPanel)), mapRect);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
}

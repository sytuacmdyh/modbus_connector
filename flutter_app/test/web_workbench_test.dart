@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/settings_store.dart';
import 'package:modbus_desktop/src/demo.dart';
import 'package:modbus_desktop/src/workspace.dart';
import 'package:modbus_desktop/src/device_panel.dart';
import 'package:modbus_desktop/src/backend/catalog_web.dart';
import 'package:modbus_desktop/src/remote/configuration.dart';
import 'package:web/web.dart' as web;

void main() {
  testWidgets(
    'WebDAV UI sync and template loading stay local with an unavailable Dart service configured',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = WorkspaceController();
      workspace.serviceConfiguration = ServiceConfiguration(
        'ws://127.0.0.1:1/ws',
        'unavailable-service-test-token',
      );
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
        await tester.tap(find.byTooltip('Workspace'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('WebDAV sync'));
        await tester.pumpAndSettle();
        expect(find.text('Mode'), findsNothing);
        expect(find.text('Publish templates'), findsNothing);
        expect(find.text('Activate version'), findsNothing);
        await tester.enterText(
          find.widgetWithText(TextField, 'WebDAV URL'),
          'http://127.0.0.1:18867/dav',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Username'),
          'operator',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Password'),
          'test-only',
        );
        await tester.tap(find.text('Download current templates'));
        Future<void> waitFor(String text) async {
          for (var i = 0; i < 100 && find.text(text).evaluate().isEmpty; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.pump(const Duration(milliseconds: 400));
          }
          expect(find.text(text), findsOneWidget);
        }

        await waitFor('Synced 1 templates');
        await tester.tap(find.text('Save connection settings'));
        await waitFor('Connection settings saved');
        final stored = web.window.localStorage.getItem(
          BrowserCatalog.cloudSettingsKey,
        )!;
        expect(stored, isNot(contains('test-only')));
        expect(
          jsonEncode(workspace.exportState()),
          isNot(contains('test-only')),
        );
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Workspace'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Templates / history'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Acme / WebDAV acceptance device'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open latest in new tab'));
        await tester.pumpAndSettle();
        expect(workspace.sessions, hasLength(2));
        expect(workspace.sessions.last.connected, false);
        expect(workspace.sessions.last.registers[1]['writable'], false);
        expect(tester.takeException(), null);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await workspace.shutdown();
        workspace.dispose();
        web.window.localStorage.removeItem(BrowserCatalog.publicStorageKey);
        web.window.localStorage.removeItem(BrowserCatalog.cloudSettingsKey);
      }
    },
  );
  testWidgets(
    'browser workspace uses the real local bridge and restores disconnected tabs',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = WorkspaceController();
      await tester.pumpWidget(
        MaterialApp(
          home: SessionWorkspace(
            controller: workspace,
            themeMode: ThemeMode.light,
            onThemeChanged: (_) {},
          ),
        ),
      );
      workspace.openState(demoState());
      final session = workspace.sessions.last;
      await tester.runAsync(() async {
        await session.connect({'transport': 'demo', 'timeout': 1.0}, 1);
        await session.registerMap.read();
      });
      await tester.pump();
      expect(session.connected, true);
      expect(session.error, null);
      expect(find.text('Demo setpoint'), findsWidgets);
      expect(session.registerMap.results[2]['display'], '10 °C');
      expect(find.byTooltip('10 °C'), findsWidgets);
      await tester.runAsync(() async {
        await session.startLogging(
          {
            'path': 'browser.csv',
            'format': 'csv',
            'interval_ms': 1000,
            'append': false,
          },
          [session.registers[2]],
        );
        await session.waitForIdle();
        session.registerMap.start(100);
        final log = await session.registerMap.betweenReads(() async {
          await session.stopLogging();
          return session.command({'command': 'logger_export'});
        });
        expect(session.registerMap.polling, true);
        session.registerMap.stop();
        await session.waitForIdle();
        expect(log!['text'], contains('Demo setpoint'));
        expect((log['text'] as String).split('\n'), hasLength(3));
      });
      final state = workspace.exportState();
      state['autosave'] = false;
      final store = SettingsStore();
      await store.save(state);
      await tester.runAsync(() async {
        await workspace.load(imported: (await store.load())!);
      });
      await tester.pump();
      expect(workspace.autoSave, false);
      expect(workspace.sessions, hasLength(2));
      expect(workspace.sessions.every((s) => !s.connected), true);
      expect(workspace.sessions.last.registers, hasLength(6));
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      await workspace.shutdown();
      workspace.dispose();
    },
  );
  testWidgets(
    'native device imports preserve configuration with an explicit capability message',
    (tester) async {
      final workspace = WorkspaceController();
      await tester.pumpWidget(
        MaterialApp(
          home: SessionWorkspace(
            controller: workspace,
            themeMode: ThemeMode.light,
            onThemeChanged: (_) {},
          ),
        ),
      );
      workspace.openState({...demoState(), 'mode': 'simulator'});
      await tester.pump();
      expect(find.byType(DevicePanel), findsNothing);
      expect(find.textContaining('This device mode requires'), findsOneWidget);
      expect(workspace.sessions.last.mode, 'simulator');
      await tester.pumpWidget(const SizedBox.shrink());
      await workspace.shutdown();
      workspace.dispose();
    },
  );
}

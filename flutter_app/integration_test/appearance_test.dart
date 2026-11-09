import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:modbus_desktop/src/desktop_table.dart';
import 'package:modbus_desktop/src/graph_dialog.dart';
import 'package:modbus_desktop/src/translations.dart';
import 'package:modbus_desktop/src/workbench_theme.dart';
import 'package:modbus_desktop/src/workspace.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'industrial theme supports native polling and minimum-size Chinese UI',
    (tester) async {
      binding.testTextInput.register();
      final workspace = WorkspaceController();
      final capture = GlobalKey();
      final previousLanguage = appLanguage.value;
      appLanguage.value = 'zh_CN';
      final output = Directory('${Directory.current.path}/build/ui_acceptance');
      await output.create(recursive: true);
      try {
        for (final scene in [
          (
            name: 'light',
            mode: ThemeMode.light,
            size: const Size(1280, 800),
            scale: 1.0,
          ),
          (
            name: 'dark',
            mode: ThemeMode.dark,
            size: const Size(1280, 800),
            scale: 1.0,
          ),
          (
            name: 'minimum',
            mode: ThemeMode.dark,
            size: const Size(900, 650),
            scale: 1.3,
          ),
        ]) {
          await binding.setSurfaceSize(scene.size);
          await tester.pumpWidget(
            MaterialApp(
              theme: workbenchTheme(Brightness.light),
              darkTheme: workbenchTheme(Brightness.dark),
              themeMode: scene.mode,
              themeAnimationDuration: Duration.zero,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: scene.size,
                  textScaler: TextScaler.linear(scene.scale),
                ),
                child: child!,
              ),
              home: RepaintBoundary(
                key: capture,
                child: SessionWorkspace(
                  controller: workspace,
                  themeMode: scene.mode,
                  onThemeChanged: (_) {},
                ),
              ),
            ),
          );
          if (scene.name == 'light') {
            await workspace.openDemo();
            for (
              var i = 0;
              i < 100 && workspace.sessions.last.registerResults.length < 6;
              i++
            ) {
              await tester.pump(const Duration(milliseconds: 100));
            }
          }
          await tester.pump(const Duration(milliseconds: 500));
          final session = workspace.sessions.last;
          expect(session.connected, isTrue);
          expect(session.registerMap.polling, isTrue);
          expect(session.registerResults, hasLength(6));
          expect(find.byType(DesktopTable), findsOneWidget);
          final trends = find.byWidgetPredicate(
            (widget) =>
                widget is CustomPaint && widget.painter is MultiSeriesPainter,
          );
          expect(trends, findsNWidgets(2));
          for (final trend in trends.evaluate()) {
            expect(trend.size!.width, greaterThanOrEqualTo(60));
            expect(trend.size!.height, 28);
          }
          if (scene.name == 'light') {
            final table = tester.getRect(find.byType(DesktopTable));
            await tester.tap(find.byTooltip(tr('Hide activity')));
            await tester.pump(const Duration(milliseconds: 200));
            expect(
              tester.getSize(find.byType(DesktopTable)).width,
              table.width,
            );
            expect(
              tester.getSize(find.byType(DesktopTable)).height,
              greaterThan(table.height),
            );
            await tester.tap(find.byTooltip(tr('Show activity')));
            await tester.pump(const Duration(milliseconds: 200));
            final selection = find
                .descendant(
                  of: find.byType(DesktopTable),
                  matching: find.byType(Checkbox),
                )
                .first;
            final viewport = tester.getRect(find.byType(DesktopTable));
            await tester.tap(selection);
            await tester.pump(const Duration(milliseconds: 100));
            expect(tester.getRect(find.byType(DesktopTable)), viewport);
            await tester.tap(selection);
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(tester.takeException(), isNull);
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${output.path}/theme-${scene.name}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          // Exercise the actual engineering-value entry point while polling.
          final target = scene.name == 'light'
              ? 235
              : scene.name == 'dark'
              ? 245
              : 255;
          await tester.ensureVisible(find.byKey(const ValueKey('map-value-2')));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.tap(find.byKey(const ValueKey('map-value-2')));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.enterText(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            ),
            '${target / 10}',
          );
          await tester.tap(find.text(tr('Apply')));
          for (
            var i = 0;
            i < 100 && session.registerResults[2]['values'].first != target;
            i++
          ) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(session.error, isNull);
          expect(session.registerResults[2]['values'], [target]);
          expect(session.registerMap.polling, isTrue);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await workspace.shutdown();
        await tester.pumpWidget(const SizedBox());
        workspace.dispose();
        appLanguage.value = previousLanguage;
        await binding.setSurfaceSize(null);
      }
    },
  );
}

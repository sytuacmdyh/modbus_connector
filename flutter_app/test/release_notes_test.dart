import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/release_info.dart';
import 'package:modbus_desktop/src/translations.dart';
import 'package:modbus_desktop/src/workspace.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets(
    'workspace version opens localized updates at desktop minimum size',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => appLanguage.value = 'en');
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
        for (final language in ['en', 'zh_CN']) {
          appLanguage.value = language;
          await tester.pumpAndSettle();
          final version = applicationVersion == 'development'
              ? tr('Development build')
              : 'v$applicationVersion';
          expect(
            find.text('$version · ${tr('Recent updates')}'),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey('workspace-release-notes')),
          );
          await tester.pumpAndSettle();
          expect(find.text(tr('Recent updates')), findsOneWidget);
          expect(find.text('v0.16.20'), findsOneWidget);
          expect(find.text('v0.16.22'), findsOneWidget);
          expect(find.text('v0.16.21'), findsOneWidget);
          expect(
            find.textContaining(
              language == 'en'
                  ? 'Choose a local JSON template'
                  : '支持选择本地 JSON 模板文件',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(tr('Close')));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await workspace.shutdown();
        workspace.dispose();
      }
    },
  );
}

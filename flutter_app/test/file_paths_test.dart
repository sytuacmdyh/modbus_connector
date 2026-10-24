import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/file_paths.dart';

void main() {
  const channel = MethodChannel('plugins.flutter.io/file_selector');
  testWidgets(
    'native open/save, cancellation and unavailable plugin path fallback',
    (tester) async {
      BuildContext? context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'openFile' ? ['/tmp/map.csv'] : '/tmp/out.csv',
      );
      expect(
        await chooseFilePath(
          context!,
          save: false,
          title: 'Import CSV file path',
          extension: 'csv',
        ),
        '/tmp/map.csv',
      );
      expect(
        await chooseFilePath(
          context!,
          save: true,
          title: 'Export CSV file path',
          extension: 'csv',
        ),
        '/tmp/out.csv',
      );
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(
        await chooseFilePath(
          context!,
          save: false,
          title: 'Import CSV file path',
          extension: 'csv',
        ),
        isNull,
      );
      expect(find.byType(AlertDialog), findsNothing);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw MissingPluginException(),
      );
      final result = chooseFilePath(
        context!,
        save: true,
        title: 'Export CSV file path',
        extension: 'csv',
        suggestedName: 'map.csv',
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '/tmp/fallback.csv');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(await result, '/tmp/fallback.csv');
      messenger.setMockMethodCallHandler(channel, null);
    },
  );
}

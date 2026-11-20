import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/translations.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Tests with English label finders choose English explicitly, independently
  // of the application's default. Localization cases switch as needed.
  setUp(() => appLanguage.value = 'en');
  await testMain();
}

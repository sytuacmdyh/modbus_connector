import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'session_controller.dart';
import 'translations.dart';

/// An owned native viewer receives only graph samples over inherited pipes.
/// It never owns a Modbus connection, workspace file or network listener.
class GraphWindowHost {
  static Future<void> open(SessionController session, {String? prefix}) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      '--graph-window',
    ]);
    Timer? timer;
    var stopped = false;
    var writing = false;
    Set<String>? selected;
    List<String> keys() => session.histories.keys
        .where((key) => prefix == null || key.startsWith(prefix))
        .toList();
    final settingsKey = 'graph:${prefix ?? 'master'}';

    Future<void> send() async {
      if (stopped || writing) return;
      writing = true;
      try {
        final available = keys();
        final wanted = selected ?? available.take(4).toSet();
        process.stdin.writeln(
          jsonEncode({
            'language': appLanguage.value,
            'theme': appTheme.value.name,
            'settings': session.draft[settingsKey],
            'labels': {
              for (final k in available) k: session.historyLabels[k] ?? k,
            },
            'series': {
              for (final k in available.where(wanted.contains))
                k: session.histories[k]!
                    .map((s) => [s.time.microsecondsSinceEpoch, s.value])
                    .toList(),
            },
          }),
        );
        await process.stdin.flush();
      } on IOException {
        timer?.cancel();
      } finally {
        writing = false;
      }
    }

    final commands = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final data = jsonDecode(line);
            if (data is! Map) return;
            if (data['selected'] is List) {
              selected = (data['selected'] as List).whereType<String>().toSet();
            }
            if (data['settings'] is Map) {
              session.draft[settingsKey] = Map<String, dynamic>.from(
                data['settings'] as Map,
              );
            }
            if (data['clear'] == true) {
              for (final k in keys()) {
                session.histories[k]?.clear();
              }
            }
          } on FormatException {
            /* Ignore native engine diagnostics on stdout. */
          }
        });
    final diagnostics = process.stderr.drain<void>();
    Future<void> close() async {
      if (stopped) return;
      stopped = true;
      timer?.cancel();
      try {
        await process.stdin.close();
      } on IOException {
        /* Already exited. */
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill();
      }
    }

    session.shutdownHooks.add(close);
    unawaited(
      process.exitCode.then((_) async {
        stopped = true;
        timer?.cancel();
        session.shutdownHooks.remove(close);
        await commands.cancel();
        await diagnostics;
      }),
    );
    timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(send()),
    );
    await send();
  }
}

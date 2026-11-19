import 'dart:convert';

import 'package:archive/archive.dart';

import 'document_file_web.dart';

/// Bounded in-memory browser diagnostics, without operating-system collection.
class Diagnostics {
  static Diagnostics? current;
  static void initialize({String role = 'ui', String? directory}) {
    current = Diagnostics();
  }

  final _events = <String>[];
  Object? get crashDumps => null;
  void write(String category, String message, [StackTrace? stack]) {
    _events.add(
      jsonEncode({
        'time': DateTime.now().toIso8601String(),
        'category': category,
        'message': message.substring(0, message.length.clamp(0, 16384)),
        if (stack != null)
          'stack': '$stack'.substring(0, '$stack'.length.clamp(0, 16384)),
      }),
    );
    if (_events.length > 256) _events.removeAt(0);
  }

  void clear({Object? dumps}) => _events.clear();
  Future<void> export(String path) async {
    final bytes = utf8.encode(_events.join('\n'));
    final archive = Archive()
      ..addFile(ArchiveFile('browser-events.jsonl', bytes.length, bytes));
    await DocumentFile(path).writeAsBytes(ZipEncoder().encode(archive));
  }
}

import 'dart:convert';

import 'package:web/web.dart' as web;

import 'document_file_web.dart';

class SettingsStore {
  static const storageKey = 'modbus_connector.workspace.v1';
  DocumentFile get file => DocumentFile('Browser storage (this site)');
  Future<void> _writing = Future.value();
  Future<Map<String, dynamic>?> load({String? path}) async {
    final text = path == null
        ? web.window.localStorage.getItem(storageKey)
        : await DocumentFile(path).readAsString();
    if (text == null) return null;
    final data = jsonDecode(text);
    if (data is! Map<String, dynamic> ||
        data['schema'] != 1 ||
        data['tabs'] is! List ||
        (data['tabs'] as List).isEmpty ||
        (data['tabs'] as List).length > 64 ||
        (data['tabs'] as List).any((t) => t is! Map<String, dynamic>)) {
      throw const FormatException(
        'Invalid Flutter workspace (schema 1, 1–64 tabs required)',
      );
    }
    return data;
  }

  Future<void> save(Map<String, dynamic> data, {String? path}) {
    final text = const JsonEncoder.withIndent('  ').convert(data);
    return _writing = _writing.catchError((Object _) {}).then((_) async {
      if (path == null) {
        web.window.localStorage.setItem(storageKey, text);
      } else {
        await DocumentFile(path).writeAsString(text);
      }
    });
  }
}

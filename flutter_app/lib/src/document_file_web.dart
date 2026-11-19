import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Opaque handles for one imported document or one browser download.
/// These are never filesystem paths and cannot access arbitrary browser files.
class DocumentFile {
  DocumentFile(this.path);
  final String path;
  static final _imports = <String, Uint8List>{};
  static int _next = 0;
  static const maxImportBytes = 20 * 1024 * 1024;

  static String importBytes(Uint8List bytes) {
    if (bytes.length > maxImportBytes) {
      throw const FormatException('File is too large (20 MiB maximum)');
    }
    final id = 'upload:${++_next}';
    // Imports are consumed when read. Bound abandoned chooser results as well.
    while (_imports.length >= 4) {
      _imports.remove(_imports.keys.first);
    }
    _imports[id] = bytes;
    return id;
  }

  Future<int> length() async => _bytes.length;
  Uint8List get _bytes =>
      _imports[path] ??
      (throw StateError(
        'Choose the file again; its upload is no longer available',
      ));
  Future<String> readAsString() async {
    final bytes = _bytes;
    _imports.remove(path);
    return utf8.decode(bytes);
  }

  Future<void> writeAsString(String text, {bool flush = false}) =>
      writeAsBytes(utf8.encode(text), flush: flush);
  Future<void> writeAsBytes(List<int> bytes, {bool flush = false}) async {
    final name = path.split(RegExp(r'[/\\]')).last;
    if (name.isEmpty || path.startsWith('upload:')) {
      throw const FormatException('Choose a download name');
    }
    final blob = web.Blob([Uint8List.fromList(bytes).toJS].toJS);
    final url = web.URL.createObjectURL(blob);
    final link = web.HTMLAnchorElement()
      ..href = url
      ..download = name;
    web.document.body?.append(link);
    link.click();
    link.remove();
    Timer(const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
  }
}

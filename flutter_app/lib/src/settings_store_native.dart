import 'dart:convert';
import 'dart:io';

/// A separate Flutter-owned directory; never reads/writes Qt settings.json.
class SettingsStore {
  SettingsStore({Directory? directory})
    : directory =
          directory ??
          Directory(
            Platform.environment['MODBUS_FLUTTER_HOME'] ??
                '${Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? Directory.current.path}${Platform.pathSeparator}.modbus_connector${Platform.pathSeparator}flutter',
          );
  final Directory directory;
  Future<void> _writing = Future.value();
  File get file =>
      File('${directory.path}${Platform.pathSeparator}settings.json');
  Future<Map<String, dynamic>?> load({String? path}) async {
    final source = path == null ? file : File(path);
    if (!await source.exists()) return null;
    final data = jsonDecode(await source.readAsString());
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

  Future<void> save(Map<String, dynamic> data, {String? path}) => _writing =
      _writing.catchError((Object _) {}).then((_) => _save(data, path: path));
  Future<void> _save(Map<String, dynamic> data, {String? path}) async {
    final target = path == null ? file : File(path);
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
    await temporary.rename(target.path);
  }
}

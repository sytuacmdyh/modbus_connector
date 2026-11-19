import 'dart:convert';

import 'data_logger.dart';
import 'registers.dart';

/// One bounded segment per session. Failed samples leave the segment intact.
class BufferedLogger {
  BufferedLogger({int capacity = 4 * 1024 * 1024})
    : _storage = _BufferStorage(capacity) {
    logger = DataLogger(_storage);
  }
  final _BufferStorage _storage;
  late final DataLogger logger;
  Future<void> close() => logger.close();
  Future<Json> dispatch(Json command) async {
    if (command['command'] == 'logger_export') {
      if (_storage.path == null) {
        throw const FormatException('No log segment to download');
      }
      return {'path': _storage.path, 'text': _storage.text.toString()};
    }
    return logger.dispatch(command);
  }
}

class _BufferStorage implements LogStorage {
  _BufferStorage(this.capacity);
  final int capacity;
  String? path;
  StringBuffer text = StringBuffer();
  int bytes = 0;
  @override
  Future<String?> existing(String path) async =>
      path == this.path ? text.toString() : null;
  @override
  Future<LogSink> open(String path, {required bool append}) async {
    if (!append || path != this.path) {
      text = StringBuffer();
      bytes = 0;
    }
    this.path = path;
    return _BufferSink(this);
  }
}

class _BufferSink implements LogSink {
  _BufferSink(this.storage);
  final _BufferStorage storage;
  bool closed = false;
  @override
  Future<int> length() async => storage.bytes;
  @override
  Future<void> writeString(String text) async {
    if (closed) throw StateError('Log is closed');
    final bytes = utf8.encode(text).length;
    if (storage.bytes + bytes > storage.capacity) {
      throw const FormatException(
        'Log capacity reached. Download the segment and start a new file.',
      );
    }
    storage.text.write(text);
    storage.bytes += bytes;
  }

  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {
    closed = true;
  }
}

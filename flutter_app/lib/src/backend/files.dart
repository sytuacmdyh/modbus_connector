import 'dart:io';
import 'dart:convert';

import 'data_logger.dart';
export 'csv.dart';

class NativeLogger extends DataLogger {
  NativeLogger({int? maxBytes}) : super(_NativeLogStorage(maxBytes));
}

class _NativeLogStorage implements LogStorage {
  _NativeLogStorage(this.maxBytes);
  final int? maxBytes;
  @override
  Future<String?> existing(String path) async {
    final file = File(path);
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<LogSink> open(String path, {required bool append}) async {
    if (maxBytes != null) await File(path).parent.create(recursive: true);
    return _NativeLogSink(
      await File(path).open(mode: append ? FileMode.append : FileMode.write),
      maxBytes,
    );
  }
}

class _NativeLogSink implements LogSink {
  _NativeLogSink(this.file, this.maxBytes);
  final RandomAccessFile file;
  final int? maxBytes;
  @override
  Future<int> length() => file.length();
  @override
  Future<void> writeString(String text) async {
    if (maxBytes != null &&
        await file.length() + utf8.encode(text).length > maxBytes!) {
      throw const FormatException(
        'Log capacity reached. Download the segment and start a new file.',
      );
    }
    await file.writeString(text);
  }

  @override
  Future<void> flush() async {
    await file.flush();
  }

  @override
  Future<void> close() async {
    await file.close();
  }
}

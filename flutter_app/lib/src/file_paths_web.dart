import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'document_file_web.dart';
import 'tool_widgets.dart';

Future<String?> chooseFilePath(
  BuildContext context, {
  required bool save,
  required String title,
  required String extension,
  String suggestedName = '',
}) async {
  if (save) {
    return textPrompt(
      context,
      'Download filename',
      value: suggestedName.isEmpty
          ? 'export.$extension'
          : suggestedName.split(RegExp(r'[/\\]')).last,
    );
  }
  final file = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
    ],
  );
  if (file == null) return null;
  if (await file.length() > DocumentFile.maxImportBytes) {
    throw const FormatException('File is too large (20 MiB maximum)');
  }
  return DocumentFile.importBytes(await file.readAsBytes());
}

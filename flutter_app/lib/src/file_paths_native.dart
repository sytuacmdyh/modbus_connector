import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tool_widgets.dart';
import 'translations.dart';

/// A cancelled native dialog stays cancelled. Unsupported hosts retain paths.
Future<String?> chooseFilePath(
  BuildContext context, {
  required bool save,
  required String title,
  required String extension,
  String suggestedName = '',
}) async {
  try {
    final types = [
      XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
    ];
    if (save) {
      return (await getSaveLocation(
        acceptedTypeGroups: types,
        suggestedName: suggestedName.isEmpty
            ? null
            : File(suggestedName).uri.pathSegments.last,
        confirmButtonText: tr('Save'),
      ))?.path;
    }
    return (await openFile(
      acceptedTypeGroups: types,
      confirmButtonText: tr('Open'),
    ))?.path;
  } on MissingPluginException {
    // Widget tests, older bundles and unsupported hosts can still use paths.
  } on UnsupportedError {
    // Some platforms support opening files but do not support save locations.
  } on PlatformException {
    // A missing desktop portal must not make local file operations unusable.
  }
  if (!context.mounted) return null;
  return textPrompt(context, title, value: save ? suggestedName : '');
}

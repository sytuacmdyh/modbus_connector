import 'dart:convert';
import 'dart:math';

import 'package:web/web.dart' as web;

import 'registers.dart';
import 'template_schema.dart';

/// Custom templates are private to this browser origin. Saves are atomic
/// localStorage replacements; quota/storage errors propagate to the caller.
class BrowserCatalog {
  static const storageKey = 'modbus_connector.templates.v1';
  static const publicStorageKey = 'modbus_connector.cloud_templates.v1';
  static const cloudSettingsKey = 'modbus_connector.cloud_settings.v1';

  Future<dynamic> loadCloudSettings() async {
    final text = web.window.localStorage.getItem(cloudSettingsKey);
    return text == null ? <String, dynamic>{} : jsonDecode(text);
  }

  Future<void> saveCloudSettings(Json settings) async =>
      web.window.localStorage.setItem(cloudSettingsKey, jsonEncode(settings));

  Future<void> replacePublic(Json catalog, void Function() check) async {
    validateCatalog(catalog);
    final text = jsonEncode(catalog);
    check();
    web.window.localStorage.setItem(publicStorageKey, text);
  }

  Json public() {
    final text = web.window.localStorage.getItem(publicStorageKey);
    if (text == null) return {};
    try {
      final catalog = map(jsonDecode(text));
      validateCatalog(catalog);
      return catalog;
    } on FormatException {
      return {};
    }
  }

  Json _load() {
    final text = web.window.localStorage.getItem(storageKey);
    if (text == null) return {};
    return map(jsonDecode(text));
  }

  void _save(Json catalog) =>
      web.window.localStorage.setItem(storageKey, jsonEncode(catalog));
  String _id() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<Json> dispatch(Json d) async {
    final command = d['command'];
    if (command == 'template_convert_workspace') {
      final workspace = map(d['workspace']), tabs = workspace['tabs'];
      if (tabs is! List ||
          tabs.isEmpty ||
          tabs.length > 64 ||
          tabs.any((t) => t is! Map)) {
        throw const FormatException(
          'Configuration requires 1..64 session objects',
        );
      }
      return {
        'schema': 1,
        'active_tab': workspace['active_tab'] ?? 0,
        'tabs': [for (final tab in tabs) flutterState(map(tab))],
      };
    }
    final catalog = _load();
    if (command == 'template_list') {
      final published = [
        for (final entry in public().entries)
          {
            'resource': entry.key,
            'manufacturer': entry.key.split('/')[0],
            'name': entry.value['name'],
            'description': entry.value['description'] ?? '',
          },
      ];
      published.sort(
        (a, b) => '${a['manufacturer']}/${a['name']}'.toLowerCase().compareTo(
          '${b['manufacturer']}/${b['name']}'.toLowerCase(),
        ),
      );
      final entries = [
        for (final e in catalog.entries) {'id': e.key, 'name': e.value['name']},
      ];
      entries.sort(
        (a, b) => '${a['name']}'.toLowerCase().compareTo(
          '${b['name']}'.toLowerCase(),
        ),
      );
      return {'public': published, 'custom': entries};
    }
    if (command == 'template_load' && d['resource'] != null) {
      final template = public()[d['resource']];
      if (template == null) {
        throw const FormatException('Public template not found');
      }
      return {'state': flutterState(map(template))};
    }
    final id = d['template_id'];
    if (command == 'template_save') {
      if (id != null && !catalog.containsKey(id)) {
        throw const FormatException('Template not found');
      }
      final identity = id as String? ?? _id();
      final data = id == null
          ? <String, dynamic>{
              'name': '${d['name'] ?? ''}'.trim(),
              'versions': <dynamic>[],
            }
          : map(catalog[id]);
      final snapshot = {...map(d['state']), 'name': data['name']};
      validateTemplate(snapshot);
      final now = DateTime.now().toUtc().toIso8601String();
      (data['versions'] as List).add({
        'id': _id(),
        'saved_at': now,
        'state': snapshot,
      });
      catalog[identity] = data;
      _save(catalog);
      return {'id': identity, 'name': data['name']};
    }
    if (id is! String || !catalog.containsKey(id)) {
      throw const FormatException('Template not found');
    }
    final data = map(catalog[id]), versions = data['versions'] as List;
    if (command == 'template_load') {
      final version = versions.reversed.firstWhere(
        (v) => d['version_id'] == null || v['id'] == d['version_id'],
        orElse: () =>
            throw const FormatException('Custom template version not found.'),
      );
      return {
        'state': flutterState({...map(version['state']), 'name': data['name']}),
        'template_id': id,
      };
    }
    if (command == 'template_versions') {
      return {
        'versions': [
          for (final version in versions.reversed)
            {'id': version['id'], 'saved_at': version['saved_at']},
        ],
      };
    }
    if (command == 'template_delete') {
      catalog.remove(id);
    } else if (command == 'template_rename') {
      final name = '${d['name'] ?? ''}'.trim();
      if (name.isEmpty) {
        throw const FormatException('Template name cannot be empty.');
      }
      catalog[id] = {...data, 'name': name};
    } else if (command == 'template_delete_version') {
      final kept = versions.where((v) => v['id'] != d['version_id']).toList();
      if (kept.length == versions.length) {
        throw const FormatException('Custom template version not found.');
      }
      if (kept.isEmpty) {
        throw const FormatException(
          'Cannot delete the last version; delete the template instead.',
        );
      }
      catalog[id] = {...data, 'versions': kept};
    } else {
      throw const FormatException('Unknown template command');
    }
    _save(catalog);
    return {};
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../settings_store.dart';
import 'registers.dart';
import 'template_schema.dart';
export 'template_schema.dart';

String randomId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
Future<dynamic> readJson(File f) async =>
    jsonDecode((await f.readAsString()).replaceFirst('\ufeff', ''));
Future<void> atomicJson(
  File f,
  dynamic data, {
  void Function()? beforeCommit,
}) async {
  await f.parent.create(recursive: true);
  final temp = File('${f.path}.${randomId()}.tmp');
  try {
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
    beforeCommit?.call();
    await temp.rename(f.path);
  } finally {
    if (await temp.exists()) await temp.delete();
  }
}

class NativeCatalog {
  NativeCatalog({Directory? directory})
    : directory = directory ?? SettingsStore().directory;
  final Directory directory;
  File file(String name) => File('${directory.path}/$name');
  Future<Json> public() async {
    final result = <String, dynamic>{};
    for (final f in [
      File('${directory.parent.path}/cloud_templates.json'),
      file('cloud_templates.json'),
    ]) {
      try {
        final data = await readJson(f);
        validateCatalog(data);
        result.addAll(map(data));
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
    return result;
  }

  File custom(dynamic id) {
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw const FormatException('Invalid custom template ID.');
    }
    return file('custom_templates/$id.json');
  }

  Future<Json> customData(dynamic id) async {
    final d = map(await readJson(custom(id)));
    if (d['schema'] != 1 ||
        d['name'] is! String ||
        (d['versions'] as List? ?? []).isEmpty) {
      throw const FormatException('Invalid custom template file.');
    }
    final seen = <String>{};
    for (final v in d['versions']) {
      if (v['id'] is! String || !seen.add(v['id'])) {
        throw const FormatException('Invalid version');
      }
      DateTime.parse(v['saved_at']);
      validateTemplate(v['state']);
    }
    return d;
  }

  Future<Json> dispatch(Json d) async {
    final cmd = d['command'], id = d['template_id'];
    if (cmd == 'template_convert_workspace') {
      final w = map(d['workspace']), tabs = w['tabs'];
      if (tabs is! List ||
          tabs.isEmpty ||
          tabs.length > 64 ||
          tabs.any((t) => t is! Map)) {
        throw const FormatException(
          'Configuration requires 1..64 session objects',
        );
      }
      const keys = {
        'mode',
        'connection',
        'registers',
        'expressions',
        'draft',
        'unit',
        'device_config',
        'sim_rows',
        'map_grouped',
        'logging',
        'scanner',
        'sniffed',
      };
      return {
        'schema': 1,
        'active_tab': w['active_tab'] ?? 0,
        'tabs': [
          for (final t in tabs)
            Map.fromEntries(
              flutterState(map(t)).entries.where((e) => keys.contains(e.key)),
            ),
        ],
      };
    }
    if (cmd == 'template_list') {
      final catalog = await public();
      final pub = [
        for (final e in catalog.entries)
          {
            'resource': e.key,
            'manufacturer': e.key.split('/')[0],
            'name': e.value['name'],
            'description': e.value['description'] ?? '',
          },
      ];
      pub.sort(
        (a, b) => '${a['manufacturer']}/${a['name']}'.toLowerCase().compareTo(
          '${b['manufacturer']}/${b['name']}'.toLowerCase(),
        ),
      );
      final own = <Json>[];
      final dir = Directory('${directory.path}/custom_templates');
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is! File || !f.path.endsWith('.json')) continue;
          final identity = f.uri.pathSegments.last.replaceAll('.json', '');
          try {
            final data = await customData(identity);
            own.add({'id': identity, 'name': data['name']});
          } catch (_) {
            continue;
          }
        }
      }
      own.sort(
        (a, b) => (a['name'] as String).toLowerCase().compareTo(
          (b['name'] as String).toLowerCase(),
        ),
      );
      return {'public': pub, 'custom': own};
    }
    if (cmd == 'template_load') {
      Json state;
      if (id != null) {
        final data = await customData(id),
            versions = (data['versions'] as List).reversed;
        final v = versions.firstWhere(
          (v) => d['version_id'] == null || v['id'] == d['version_id'],
          orElse: () =>
              throw const FormatException('Custom template version not found.'),
        );
        state = {...map(v['state']), 'name': data['name']};
      } else {
        final catalog = await public();
        if (!catalog.containsKey(d['resource'])) {
          throw const FormatException('Template not found');
        }
        state = map(catalog[d['resource']]);
      }
      return {'state': flutterState(state), 'template_id': id};
    }
    if (cmd == 'template_save') {
      final state = map(d['state']);
      final identity = id ?? randomId();
      final data = id != null
          ? await customData(id)
          : {
              'schema': 1,
              'name': '${d['name'] ?? ''}'.trim(),
              'versions': <dynamic>[],
            };
      if ((data['name'] as String).isEmpty) {
        throw const FormatException('Template name cannot be empty.');
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final snapshot = {...state, 'name': data['name']};
      validateTemplate(snapshot);
      (data['versions'] as List).add({
        'id': '$now-${randomId().substring(0, 8)}',
        'saved_at': now,
        'state': snapshot,
      });
      await atomicJson(custom(identity), data);
      return {'id': identity, 'name': data['name']};
    }
    final data = await customData(id), versions = data['versions'] as List;
    if (cmd == 'template_versions') {
      return {
        'versions': [
          for (final v in versions.reversed)
            {'id': v['id'], 'saved_at': v['saved_at']},
        ],
      };
    }
    if (cmd == 'template_delete') {
      await custom(id).delete();
      return {};
    }
    if (cmd == 'template_rename') {
      final name = '${d['name'] ?? ''}'.trim();
      if (name.isEmpty) {
        throw const FormatException('Template name cannot be empty.');
      }
      data['name'] = name;
    } else if (cmd == 'template_delete_version') {
      final kept = versions.where((v) => v['id'] != d['version_id']).toList();
      if (kept.length == versions.length) {
        throw const FormatException('Custom template version not found.');
      }
      if (kept.isEmpty) {
        throw const FormatException(
          'Cannot delete the last version; delete the template instead.',
        );
      }
      data['versions'] = kept;
    } else {
      throw const FormatException('Unknown template command');
    }
    await atomicJson(custom(id), data);
    return {};
  }
}

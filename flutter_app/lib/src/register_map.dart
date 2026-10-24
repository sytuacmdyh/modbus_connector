import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'tool_widgets.dart';

const displayFormats = [
  'dec',
  'hex',
  's16',
  'u32',
  's32',
  'f32',
  'u64',
  's64',
  'f64',
  'ascii',
  'ascii1',
];
const csvColumns = [
  'name',
  'kind',
  'address',
  'count',
  'unit_id',
  'poll_ms',
  'format',
  'scale',
  'offset',
  'unit',
  'order',
];

class RegisterMapController extends ChangeNotifier {
  RegisterMapController(this.session);
  final SessionController session;
  bool reading = false;
  bool polling = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _timer;
  List<Map<String, dynamic>> get rows => session.registers;
  List<Map<String, dynamic>> get results => session.registerResults;
  Future<void> read() async {
    if (reading || session.busy || !session.connected || rows.isEmpty) return;
    reading = true;
    final generation = _generation;
    session.beginTool();
    notifyListeners();
    try {
      final next = <Map<String, dynamic>>[];
      for (final row in List.of(rows)) {
        final reply = await session.command({
          'command': 'read_rows',
          'unit': session.unit,
          'rows': [row],
        });
        if (_disposed || generation != _generation) return;
        if (reply == null) {
          stop();
          return;
        }
        next.add((reply['rows'] as List).single as Map<String, dynamic>);
      }
      results
        ..clear()
        ..addAll(next);
    } finally {
      reading = false;
      session.endTool();
      if (!_disposed) notifyListeners();
    }
  }

  void start(int interval) {
    if (polling) return;
    polling = true;
    _timer = Timer.periodic(
      Duration(milliseconds: interval),
      (_) => unawaited(read()),
    );
    unawaited(read());
    notifyListeners();
  }

  void stop() {
    polling = false;
    _timer?.cancel();
    ++_generation;
    if (!_disposed) notifyListeners();
  }

  void changed() {
    stop();
    results.clear();
    notifyListeners();
  }

  void capture(String name) {
    session.snapshots[name] = List.generate(
      rows.length,
      (i) => i < results.length ? List.of(results[i]['values'] as List) : null,
    );
    notifyListeners();
  }

  List<String> diff(String name) {
    final old = session.snapshots[name] ?? [];
    final changes = <String>[];
    for (var i = 0; i < rows.length; i++) {
      final before = i < old.length ? old[i] : null;
      final after = i < results.length ? results[i]['values'] : null;
      if (jsonEncode(before) != jsonEncode(after)) {
        changes.add(
          '${rows[i]['name']} @${rows[i]['address']}: $before → $after',
        );
      }
    }
    return changes;
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}

class RegisterMapDialog extends StatefulWidget {
  const RegisterMapDialog({super.key, required this.session});
  final SessionController session;
  @override
  State<RegisterMapDialog> createState() => _RegisterMapDialogState();
}

class _RegisterMapDialogState extends State<RegisterMapDialog> {
  late final model = RegisterMapController(widget.session);
  int interval = 500;
  String? message;
  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  Future<void> edit([int? index]) async {
    model.stop();
    final row = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          RegisterRowDialog(row: index == null ? null : model.rows[index]),
    );
    if (row != null && mounted) {
      setState(() {
        if (index == null) {
          model.rows.add(row);
        } else {
          model.rows[index] = row;
        }
      });
      model.changed();
    }
  }

  Future<void> csvImport() async {
    final path = await textPrompt(context, 'Import CSV file path');
    if (path == null || path.isEmpty || !mounted) return;
    try {
      final content = await File(path).readAsString();
      final preview = await widget.session.command({
        'command': 'csv_parse',
        'text': content,
        'preview': true,
      });
      if (preview == null || !mounted) return;
      final mapping = await showDialog<Map<String, String>>(
        context: context,
        builder: (_) => CsvMappingDialog(preview: preview),
      );
      if (mapping == null) return;
      final parsed = await widget.session.command({
        'command': 'csv_parse',
        'text': content,
        'mapping': mapping,
      });
      if (parsed != null && mounted) {
        model.rows.addAll(
          (parsed['rows'] as List).cast<Map<String, dynamic>>(),
        );
        model.changed();
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> csvExport() async {
    final columns = <String>{...csvColumns};
    final chosen = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Export columns'),
          content: SizedBox(
            width: 450,
            child: Wrap(
              children: [
                for (final c in csvColumns)
                  FilterChip(
                    label: Text(c),
                    selected: columns.contains(c),
                    onSelected: (v) => update(() {
                      if (v) {
                        columns.add(c);
                      } else {
                        columns.remove(c);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: columns.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    if (chosen != true || !mounted) return;
    final path = await textPrompt(context, 'Export CSV file path');
    if (path == null || path.isEmpty) return;
    try {
      final result = await widget.session.command({
        'command': 'csv_export',
        'rows': model.rows,
        'columns': csvColumns.where(columns.contains).toList(),
      });
      if (result == null) return;
      await File(path).writeAsString(result['text'] as String, flush: true);
      if (mounted) setState(() => message = 'Saved $path');
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> write(int i, {bool bits = false}) async {
    model.stop();
    if (model.reading || widget.session.busy) return;
    final row = model.rows[i];
    final raw = i < model.results.length
        ? model.results[i]['values'] as List
        : [];
    List<dynamic>? values;
    if (bits) {
      final value = await showDialog<int>(
        context: context,
        builder: (_) => BitsDialog(
          value: raw.isEmpty ? 0 : (raw.first as num).toInt(),
          names: (row['value_names'] as Map?)?.cast<String, dynamic>() ?? {},
        ),
      );
      if (value == null) return;
      values = [value];
    } else {
      final content = await textPrompt(
        context,
        'Write ${row['name']} (${row['format']}, engineering units)',
        value: '',
      );
      if (content == null) return;
      final encoded = await widget.session.command({
        'command': 'encode_values',
        'row': row,
        'text': content,
      });
      values = encoded?['values'] as List?;
    }
    if (values == null) return;
    await widget.session.command({
      'command': 'write',
      'unit': row['unit_id'] ?? widget.session.unit,
      'kind': row['kind'],
      'address': row['address'],
      'values': values,
    });
    await model.read();
  }

  Future<void> snapshot() async {
    final name = await textPrompt(context, 'Snapshot name');
    if (name != null && name.trim().isNotEmpty && mounted) {
      model.capture(name.trim());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([model, widget.session]),
    builder: (context, _) => AlertDialog(
      title: const Text('Register map'),
      content: SizedBox(
        width: 800,
        height: 470,
        child: Column(
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                OutlinedButton(
                  onPressed: model.reading || model.rows.length >= 512
                      ? null
                      : edit,
                  child: const Text('Add row'),
                ),
                OutlinedButton(
                  onPressed: model.reading ? null : csvImport,
                  child: const Text('Import CSV'),
                ),
                OutlinedButton(
                  onPressed: model.reading ? null : csvExport,
                  child: const Text('Export CSV'),
                ),
                OutlinedButton(
                  onPressed: model.reading ? null : snapshot,
                  child: const Text('Snapshot'),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Compare snapshot',
                  onSelected: (name) => showText(
                    context,
                    'Snapshot $name differences',
                    model.diff(name).join('\n').isEmpty
                        ? 'No differences'
                        : model.diff(name).join('\n'),
                  ),
                  itemBuilder: (_) => widget.session.snapshots.keys
                      .map((n) => PopupMenuItem(value: n, child: Text(n)))
                      .toList(),
                  icon: const Icon(Icons.compare),
                ),
                OutlinedButton(
                  onPressed: !widget.session.connected || model.reading
                      ? null
                      : model.read,
                  child: const Text('Read map'),
                ),
                FilledButton.tonal(
                  onPressed: model.polling
                      ? model.stop
                      : !widget.session.connected
                      ? null
                      : () => model.start(interval),
                  child: Text(model.polling ? 'Stop' : 'Poll map'),
                ),
                toolChoice(
                  'Interval, ms',
                  '$interval',
                  ['100', '500', '1000', '5000'],
                  model.polling
                      ? null
                      : (v) => setState(() => interval = int.parse(v)),
                  width: 125,
                ),
              ],
            ),
            if (model.reading) const LinearProgressIndicator(),
            if (message != null) Text(message!),
            if (widget.session.error != null)
              Text(widget.session.error!, maxLines: 2),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: model.rows.length,
                itemBuilder: (context, i) {
                  final row = model.rows[i];
                  final result = i < model.results.length
                      ? model.results[i]
                      : null;
                  final writable =
                      row['kind'] == 'holding_registers' ||
                      row['kind'] == 'coils';
                  return ListTile(
                    dense: true,
                    title: Text(
                      '${row['name']} · ${row['kind']} @${row['address']} ×${row['count']} · unit ${row['unit_id'] ?? widget.session.unit}',
                    ),
                    subtitle: Text(
                      '${row['format']} · ${result?['display'] ?? '—'}',
                      style: TextStyle(
                        color: result?['alarm'] == null
                            ? null
                            : (result!['alarm']['color'] == 'yellow'
                                  ? Colors.amber.shade800
                                  : Colors.red),
                      ),
                    ),
                    onTap: model.reading ? null : () => edit(i),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (row['kind'] == 'holding_registers' &&
                            row['count'] == 1)
                          IconButton(
                            tooltip: 'Edit bits',
                            onPressed: !widget.session.canRead || model.reading
                                ? null
                                : () => write(i, bits: true),
                            icon: const Icon(Icons.grid_4x4, size: 18),
                          ),
                        IconButton(
                          tooltip: 'Write row',
                          onPressed:
                              !writable ||
                                  !widget.session.canRead ||
                                  model.reading
                              ? null
                              : () => write(i),
                          icon: const Icon(Icons.edit_note),
                        ),
                        IconButton(
                          tooltip: 'Delete row',
                          onPressed: model.reading
                              ? null
                              : () {
                                  model.rows.removeAt(i);
                                  model.changed();
                                },
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (model.rows.isEmpty)
              const Text(
                'Add named rows at any unit/address, or import a CSV/template.',
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            model.stop();
            Navigator.pop(context);
          },
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class RegisterRowDialog extends StatefulWidget {
  const RegisterRowDialog({super.key, this.row});
  final Map<String, dynamic>? row;
  @override
  State<RegisterRowDialog> createState() => _RegisterRowDialogState();
}

class _RegisterRowDialogState extends State<RegisterRowDialog> {
  final fields = <String, TextEditingController>{};
  late String kind = widget.row?['kind'] as String? ?? 'holding_registers';
  late String format = widget.row?['format'] as String? ?? 'dec';
  late String order = widget.row?['order'] as String? ?? 'ABCD';
  late bool bitmask = widget.row?['bitmask'] == true;
  String? error;
  @override
  void initState() {
    super.initState();
    for (final e in {
      'name': 'Register',
      'address': 0,
      'count': 1,
      'unit_id': '',
      'scale': 1,
      'offset': 0,
      'unit': '',
    }.entries) {
      fields[e.key] = TextEditingController(
        text: '${widget.row?[e.key] ?? e.value}',
      );
    }
    final names = widget.row?['value_names'] as Map? ?? {};
    fields['names'] = TextEditingController(
      text: names.entries.map((e) => '${e.key}=${e.value}').join('\n'),
    );
  }

  @override
  void dispose() {
    for (final f in fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  void save() {
    final address = int.tryParse(fields['address']!.text);
    final count = int.tryParse(fields['count']!.text);
    final unit = fields['unit_id']!.text.isEmpty
        ? null
        : int.tryParse(fields['unit_id']!.text);
    final scale = double.tryParse(fields['scale']!.text);
    final offset = double.tryParse(fields['offset']!.text);
    final width = ['u64', 's64', 'f64'].contains(format)
        ? 4
        : ['u32', 's32', 'f32'].contains(format)
        ? 2
        : 1;
    final bit = kind == 'coils' || kind == 'discrete_inputs';
    if (address == null ||
        count == null ||
        address < 0 ||
        count < (bit ? 1 : width) ||
        count > (bit ? 2000 : 125) ||
        address + count > 65536 ||
        (fields['unit_id']!.text.isNotEmpty &&
            (unit == null || unit < 1 || unit > 247)) ||
        scale == null ||
        !scale.isFinite ||
        offset == null ||
        !offset.isFinite) {
      setState(
        () => error = 'Check address/count, format width, unit (1–247), and finite scale/offset.',
      );
      return;
    }
    final names = <String, String>{};
    for (final line in fields['names']!.text.split('\n')) {
      final p = line.indexOf('=');
      if (p > 0 && int.tryParse(line.substring(0, p).trim()) != null) {
        names[line.substring(0, p).trim()] = line.substring(p + 1).trim();
      }
    }
    Navigator.pop(context, {
      ...?widget.row,
      'name': fields['name']!.text,
      'kind': kind,
      'address': address,
      'count': count,
      'unit_id': unit,
      'format': format,
      'order': order,
      'scale': scale,
      'offset': offset,
      'unit': fields['unit']!.text,
      'value_names': names,
      'bitmask': bitmask,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Register row'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                toolField('Name', fields['name']!, width: 260),
                toolChoice(
                  'Area',
                  kind,
                  areas.keys,
                  (v) => setState(() => kind = v),
                  width: 260,
                ),
                for (final key in ['address', 'count', 'unit_id'])
                  toolField(key, fields[key]!, width: 160),
                toolChoice(
                  'Format',
                  format,
                  displayFormats,
                  (v) => setState(() => format = v),
                  width: 160,
                ),
                toolChoice(
                  'Byte order',
                  order,
                  ['ABCD', 'CDAB', 'BADC', 'DCBA'],
                  (v) => setState(() => order = v),
                  width: 160,
                ),
                for (final key in ['scale', 'offset', 'unit'])
                  toolField(key, fields[key]!, width: 160),
                toolField(
                  'Value names: number=name (one per line)',
                  fields['names']!,
                  width: 540,
                  lines: 3,
                ),
              ],
            ),
            CheckboxListTile(
              title: const Text('Names label bits 0–15'),
              value: bitmask,
              onChanged: (v) => setState(() => bitmask = v!),
            ),
            if (error != null) Text(error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: save, child: const Text('Apply')),
    ],
  );
}

class BitsDialog extends StatefulWidget {
  const BitsDialog({super.key, required this.value, this.names = const {}});
  final int value;
  final Map<String, dynamic> names;
  @override
  State<BitsDialog> createState() => _BitsDialogState();
}

class _BitsDialogState extends State<BitsDialog> {
  late int value = widget.value;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Bits · 0x${value.toRadixString(16).padLeft(4, '0')}'),
    content: SizedBox(
      width: 480,
      height: 330,
      child: GridView.count(
        crossAxisCount: 2,
        childAspectRatio: 5,
        children: [
          for (var bit = 0; bit < 16; bit++)
            CheckboxListTile(
              dense: true,
              title: Text('b$bit ${widget.names['$bit'] ?? ''}'),
              value: value & (1 << bit) != 0,
              onChanged: (v) => setState(
                () => value = v! ? value | (1 << bit) : value & ~(1 << bit),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, value),
        child: const Text('Write'),
      ),
    ],
  );
}

class CsvMappingDialog extends StatefulWidget {
  const CsvMappingDialog({super.key, required this.preview});
  final Map<String, dynamic> preview;
  @override
  State<CsvMappingDialog> createState() => _CsvMappingDialogState();
}

class _CsvMappingDialogState extends State<CsvMappingDialog> {
  late final mapping = (widget.preview['mapping'] as Map)
      .cast<String, String>();
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('CSV column mapping'),
    content: SizedBox(
      width: 500,
      height: 350,
      child: ListView(
        children: [
          for (final column
              in (widget.preview['header'] as List).cast<String>())
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(child: Text(column)),
                  toolChoice(
                    'Field',
                    mapping[column] ?? 'Ignore',
                    ['Ignore', ...csvColumns],
                    (v) => setState(() {
                      if (v == 'Ignore') {
                        mapping.remove(column);
                      } else {
                        mapping[column] = v;
                      }
                    }),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: ['name', 'kind', 'address'].every(mapping.values.contains)
            ? () => Navigator.pop(context, mapping)
            : null,
        child: const Text('Import'),
      ),
    ],
  );
}

import 'file_paths.dart';
import 'desktop_table.dart';
import 'translations.dart';

import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'session_controller.dart';
export 'register_map_controller.dart';
import 'tool_widgets.dart';
import 'logging_dialog.dart';
import 'graph_dialog.dart';
import 'expression_dialog.dart';

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

class RegisterMapDialog extends StatelessWidget {
  const RegisterMapDialog({super.key, required this.session});
  final SessionController session;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const LText('Register map'),
    content: SizedBox(
      width: 1000,
      height: 470,
      child: SingleChildScrollView(
        child: RegisterMapPanel(
          session: session,
          autofocus: true,
          shrinkWrap: true,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const LText('Close'),
      ),
    ],
  );
}

class RegisterMapPanel extends StatefulWidget {
  final bool autofocus;
  const RegisterMapPanel({
    super.key,
    required this.session,
    this.autofocus = false,
    this.shrinkWrap = false,
  });
  final SessionController session;
  final bool shrinkWrap;
  @override
  State<RegisterMapPanel> createState() => _RegisterMapPanelState();
}

class _RegisterMapPanelState extends State<RegisterMapPanel> {
  late final model = widget.session.registerMap;
  late int interval =
      const [
        100,
        500,
        1000,
        5000,
      ].contains(widget.session.draft['map_interval'])
      ? widget.session.draft['map_interval'] as int
      : 500;
  final selectedRows = <int>{};
  final nameFilter = TextEditingController();
  final addressFilter = TextEditingController();
  final filterFocus = FocusNode();
  String pollingFilter = 'all';
  String areaFilter = 'all';
  String? message;

  ({int start, int end})? get addressRange {
    final match = RegExp(
      r'^(0[xX][0-9a-fA-F]+|\d+)(?:\s*[-–]\s*(0[xX][0-9a-fA-F]+|\d+))?$',
    ).firstMatch(addressFilter.text.trim());
    if (match == null) return null;
    final start = int.tryParse(match[1]!);
    final end = int.tryParse(match[2] ?? match[1]!);
    if (start == null || end == null || start > end || end > 65535) {
      return null;
    }
    return (start: start, end: end);
  }

  List<int> get visibleRows {
    final name = nameFilter.text.trim().toLowerCase();
    final range = addressRange;
    if (addressFilter.text.trim().isNotEmpty && range == null) return [];
    final indices = <int>[];
    for (var i = 0; i < model.rows.length; i++) {
      final row = model.rows[i];
      final rowName = '${row['name'] ?? ''}';
      if (!rowName.toLowerCase().contains(name) &&
          !tr(rowName).toLowerCase().contains(name)) {
        continue;
      }
      if (areaFilter != 'all' && row['kind'] != areaFilter) continue;
      final enabled = row['poll_enabled'] != false;
      if (pollingFilter == 'enabled' && !enabled ||
          pollingFilter == 'disabled' && enabled) {
        continue;
      }
      if (range != null) {
        final start = row['address'] as int? ?? 0;
        final end = start + (row['count'] as int? ?? 1) - 1;
        if (start > range.end || end < range.start) continue;
      }
      indices.add(i);
    }
    return indices;
  }

  Set<int> get visibleSelection =>
      selectedRows.intersection(visibleRows.toSet());

  void changeFilters(VoidCallback change) => setState(() {
    change();
    selectedRows.clear();
  });

  @override
  void dispose() {
    nameFilter.dispose();
    addressFilter.dispose();
    filterFocus.dispose();
    super.dispose();
  }

  void valueAction(String action) {
    final selected = visibleSelection;
    if (selected.length != 1) return;
    final i = selected.single;
    if (i < 0 || i >= model.rows.length) return;
    if (action == 'copy') {
      if (i < model.results.length) {
        Clipboard.setData(
          ClipboardData(text: '${model.results[i]['display'] ?? ''}'),
        );
      }
    } else {
      model.quickValue(i, action);
    }
  }

  void batch(String action) {
    if ([
      'copy',
      'zero',
      'one',
      'increment',
      'decrement',
      'toggle',
    ].contains(action)) {
      valueAction(action);
      return;
    }
    if (model.reading || widget.session.busy) return;
    final visible = visibleRows;
    final indices = visible.where(selectedRows.contains).toList();
    if (action == 'all') {
      setState(() {
        if (visible.every(selectedRows.contains)) {
          selectedRows.removeAll(visible);
        } else {
          selectedRows.addAll(visible);
        }
      });
      return;
    }
    if (indices.isEmpty) return;
    if (action == 'read') {
      model.read(onlyIndices: indices.toSet());
      return;
    }
    model.stop();
    setState(() {
      if (action == 'delete') {
        for (final i in indices.reversed) {
          model.rows.removeAt(i);
        }
        selectedRows.clear();
      } else if (action == 'duplicate') {
        for (final i in indices) {
          if (model.rows.length >= maxRegisterRows) break;
          final copy =
              jsonDecode(jsonEncode(model.rows[i])) as Map<String, dynamic>;
          copy['name'] = '${copy['name']} ${tr('copy')}';
          model.rows.add(copy);
        }
      } else if (action == 'up' || action == 'down') {
        final step = action == 'up' ? -1 : 1;
        for (final i in step < 0 ? indices : indices.reversed) {
          final at = visible.indexOf(i) + step;
          if (at < 0 || at >= visible.length) continue;
          final next = visible[at];
          if (selectedRows.contains(next)) continue;
          final row = model.rows[i];
          model.rows[i] = model.rows[next];
          model.rows[next] = row;
          selectedRows
            ..remove(i)
            ..add(next);
        }
      } else if (action == 'trend_on' || action == 'trend_off') {
        for (final i in indices) {
          model.rows[i]['trend_enabled'] = action == 'trend_on';
        }
      } else {
        for (final i in indices) {
          model.rows[i]['poll_enabled'] = action == 'enable';
        }
      }
    });
    model.changed();
  }

  List<PopupMenuEntry<String>> rowActions() => const [
    PopupMenuItem(value: 'read', child: LText('Read selected rows')),
    PopupMenuItem(value: 'copy', child: LText('Copy value')),
    PopupMenuItem(value: 'zero', child: LText('Write 0')),
    PopupMenuItem(value: 'one', child: LText('Write 1')),
    PopupMenuItem(value: 'increment', child: LText('Increment')),
    PopupMenuItem(value: 'decrement', child: LText('Decrement')),
    PopupMenuItem(value: 'toggle', child: LText('Toggle')),
    PopupMenuDivider(),
    PopupMenuItem(value: 'trend_on', child: LText('Enable trend')),
    PopupMenuItem(value: 'trend_off', child: LText('Disable trend')),
    PopupMenuItem(value: 'enable', child: LText('Enable selected polling')),
    PopupMenuItem(value: 'disable', child: LText('Disable selected polling')),
    PopupMenuItem(value: 'duplicate', child: LText('Duplicate selected rows')),
    PopupMenuItem(value: 'up', child: LText('Move up')),
    PopupMenuItem(value: 'down', child: LText('Move down')),
    PopupMenuItem(value: 'delete', child: LText('Delete selected rows')),
  ];

  Future<void> rowMenu(int i, Offset position) async {
    if (model.reading) return;
    setState(() {
      if (!selectedRows.contains(i)) {
        selectedRows
          ..clear()
          ..add(i);
      }
    });
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: rowActions(),
    );
    if (mounted && action != null) batch(action);
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
    final path = await chooseFilePath(
      context,
      save: false,
      title: 'Import CSV file path',
      extension: 'csv',
    );
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
      if (mounted) setState(() => message = userError(e));
    }
  }

  Future<void> csvExport() async {
    final columns = <String>{...csvColumns, 'value'};
    final chosen = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const LText('Export columns'),
          content: SizedBox(
            width: 450,
            child: Wrap(
              children: [
                for (final c in [...csvColumns, 'value'])
                  FilterChip(
                    label: LText(c),
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
              child: const LText('Cancel'),
            ),
            FilledButton(
              onPressed: columns.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: const LText('Continue'),
            ),
          ],
        ),
      ),
    );
    if (chosen != true || !mounted) return;
    final path = await chooseFilePath(
      context,
      save: true,
      title: 'Export CSV file path',
      extension: 'csv',
      suggestedName: 'registers.csv',
    );
    if (path == null || path.isEmpty) return;
    try {
      final result = await widget.session.command({
        'command': 'csv_export',
        'rows': List.generate(
          model.rows.length,
          (i) => <String, dynamic>{
            ...model.rows[i],
            if (i < model.results.length) 'values': model.results[i]['values'],
          },
        ),
        'columns': [...csvColumns, 'value'].where(columns.contains).toList(),
      });
      if (result == null) return;
      await File(path).writeAsString(result['text'] as String, flush: true);
      if (mounted) setState(() => message = 'Saved $path');
    } catch (e) {
      if (mounted) setState(() => message = userError(e));
    }
  }

  Future<void> writeRaw(int i, List<dynamic> values) async {
    model.stop();
    if (model.reading || widget.session.busy) return;
    final row = model.rows[i];
    await widget.session.command({
      'command': 'write',
      'unit': row['unit_id'] ?? widget.session.unit,
      'kind': row['kind'],
      'address': row['address'],
      'values': values,
    });
    await model.read();
  }

  Future<void> write(int i, {bool bits = false}) async {
    model.stop();
    if (model.reading || widget.session.busy) return;
    final row = model.rows[i];
    final raw = i < model.results.length
        ? model.results[i]['values'] as List? ?? []
        : [];
    List<dynamic>? values;
    if (!bits && hasRawEditor(row)) {
      values = await rawValuePrompt(context, row, raw);
    } else if (bits) {
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
        trf('Write {name} ({format}, engineering units)', {
          'name': row['name'],
          'format': row['format'],
        }),
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

  Future<void> snapshotFile(bool save) async {
    final path = await chooseFilePath(
      context,
      save: save,
      title: save ? 'Export snapshots file path' : 'Import snapshots file path',
      extension: 'json',
      suggestedName: 'snapshots.json',
    );
    if (path == null || path.isEmpty) return;
    try {
      if (save) {
        await File(path).writeAsString(
          jsonEncode({'schema': 1, 'snapshots': widget.session.snapshots}),
          flush: true,
        );
      } else {
        final data = jsonDecode(await File(path).readAsString());
        if (data is! Map || data['schema'] != 1 || data['snapshots'] is! Map) {
          throw const FormatException('Invalid snapshots file');
        }
        final parsed = <String, List<Object?>>{};
        for (final e in (data['snapshots'] as Map).entries) {
          if (e.key is! String ||
              e.value is! List ||
              (e.value as List).any(
                (r) =>
                    r is! Map ||
                    r['key'] is! String ||
                    r['name'] is! String ||
                    (r['values'] != null && r['values'] is! List),
              )) {
            throw const FormatException('Invalid snapshots file');
          }
          parsed[e.key as String] = List<Object?>.from(e.value as List);
        }
        widget.session.snapshots.addAll(parsed);
      }
      if (mounted) {
        setState(
          () =>
              message = tr(save ? 'Snapshots exported' : 'Snapshots imported'),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => message = '${tr('Snapshot file failed')}: ${userError(e)}',
        );
      }
    }
  }

  Future<void> snapshot() async {
    final name = await textPrompt(context, 'Snapshot name');
    if (name != null && name.trim().isNotEmpty && mounted) {
      model.capture(name.trim());
    }
  }

  Widget filterBar(int shown) => Theme(
    data: Theme.of(context).copyWith(
      inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
    ),
    child: Focus(
      focusNode: filterFocus,
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 160,
            child: TextField(
              key: const ValueKey('map-filter-name'),
              controller: nameFilter,
              decoration: InputDecoration(labelText: tr('Filter by name')),
              onChanged: (_) => changeFilters(() {}),
            ),
          ),
          SizedBox(
            width: 150,
            child: TextField(
              key: const ValueKey('map-filter-address'),
              controller: addressFilter,
              decoration: InputDecoration(
                labelText: tr('Address / range'),
                hintText: '100 / 100-200',
                errorText:
                    addressFilter.text.trim().isNotEmpty && addressRange == null
                    ? tr('Invalid address range')
                    : null,
                errorMaxLines: 2,
              ),
              onChanged: (_) => changeFilters(() {}),
            ),
          ),
          SizedBox(
            width: 140,
            child: DropdownButtonFormField<String>(
              key: const ValueKey('map-filter-polling'),
              initialValue: pollingFilter,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('Polling status')),
              items: const [
                DropdownMenuItem(value: 'all', child: LText('All rows')),
                DropdownMenuItem(
                  value: 'enabled',
                  child: LText('Enabled only'),
                ),
                DropdownMenuItem(
                  value: 'disabled',
                  child: LText('Disabled only'),
                ),
              ],
              onChanged: (value) {
                if (value != null) changeFilters(() => pollingFilter = value);
              },
            ),
          ),
          SizedBox(
            width: 185,
            child: DropdownButtonFormField<String>(
              key: const ValueKey('map-filter-area'),
              initialValue: areaFilter,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr('Function area')),
              items: [
                const DropdownMenuItem(value: 'all', child: LText('All areas')),
                for (final entry in areas.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: LText(entry.value, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                if (value != null) changeFilters(() => areaFilter = value);
              },
            ),
          ),
          IconButton(
            tooltip: tr('Clear filters'),
            onPressed:
                nameFilter.text.isEmpty &&
                    addressFilter.text.isEmpty &&
                    pollingFilter == 'all' &&
                    areaFilter == 'all'
                ? null
                : () => changeFilters(() {
                    nameFilter.clear();
                    addressFilter.clear();
                    pollingFilter = 'all';
                    areaFilter = 'all';
                  }),
            icon: const Icon(Icons.filter_alt_off_outlined, size: 20),
          ),
          LText(
            trf('Showing {shown} / {total}', {
              'shown': shown,
              'total': model.rows.length,
            }),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );

  Widget toolbarMenuLabel(IconData icon, String label, {bool enabled = true}) {
    final color = enabled ? null : Theme.of(context).disabledColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: IconTheme.merge(
        data: IconThemeData(size: 18, color: color),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon),
            const SizedBox(width: 6),
            LText(label, style: TextStyle(color: color)),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([model, widget.session, appLanguage]),
    builder: (context, _) {
      final visible = visibleRows;
      final hasSelection = visible.any(selectedRows.contains);
      return CallbackShortcuts(
        bindings: filterFocus.hasFocus
            ? const {}
            : {
                const SingleActivator(
                  LogicalKeyboardKey.keyC,
                  control: true,
                ): () =>
                    valueAction('copy'),
                const SingleActivator(
                  LogicalKeyboardKey.digit0,
                  control: true,
                ): () =>
                    valueAction('zero'),
                const SingleActivator(
                  LogicalKeyboardKey.digit1,
                  control: true,
                ): () =>
                    valueAction('one'),
                const SingleActivator(
                  LogicalKeyboardKey.equal,
                  control: true,
                ): () =>
                    valueAction('increment'),
                const SingleActivator(
                  LogicalKeyboardKey.minus,
                  control: true,
                ): () =>
                    valueAction('decrement'),
                const SingleActivator(
                  LogicalKeyboardKey.keyT,
                  control: true,
                ): () =>
                    valueAction('toggle'),
                const SingleActivator(
                  LogicalKeyboardKey.keyA,
                  control: true,
                ): () =>
                    batch('all'),
                const SingleActivator(
                  LogicalKeyboardKey.keyR,
                  control: true,
                ): () {
                  if (!hasSelection) {
                    model.read();
                  } else {
                    batch('read');
                  }
                },
                const SingleActivator(
                  LogicalKeyboardKey.keyR,
                  control: true,
                  shift: true,
                ): () =>
                    model.read(),
                const SingleActivator(
                  LogicalKeyboardKey.arrowUp,
                  control: true,
                ): () =>
                    batch('up'),
                const SingleActivator(
                  LogicalKeyboardKey.arrowDown,
                  control: true,
                ): () =>
                    batch('down'),
                const SingleActivator(LogicalKeyboardKey.delete): () =>
                    batch('delete'),
                const SingleActivator(
                  LogicalKeyboardKey.keyN,
                  control: true,
                ): () {
                  if (!model.reading) edit();
                },
              },
        child: Focus(
          autofocus: widget.autofocus,
          child: Column(
            mainAxisSize: widget.shrinkWrap
                ? MainAxisSize.min
                : MainAxisSize.max,
            children: [
              // Acquisition stays above editing tools at every window width.
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: !widget.session.connected || model.reading
                          ? null
                          : model.read,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const LText('Read map'),
                    ),
                    FilledButton.icon(
                      onPressed: model.polling
                          ? model.stop
                          : !widget.session.connected
                          ? null
                          : () => model.start(interval),
                      icon: Icon(
                        model.polling ? Icons.stop : Icons.play_arrow,
                        size: 18,
                      ),
                      label: LText(model.polling ? 'Stop' : 'Poll map'),
                    ),
                    toolChoice(
                      'Interval, ms',
                      '$interval',
                      ['100', '500', '1000', '5000'],
                      model.polling
                          ? null
                          : (v) => setState(() {
                              interval = int.parse(v);
                              widget.session.draft['map_interval'] = interval;
                            }),
                      width: 125,
                    ),
                    FilterChip(
                      label: const LText('Group reads'),
                      selected: widget.session.mapGrouped,
                      onSelected: model.reading
                          ? null
                          : (v) =>
                                setState(() => widget.session.mapGrouped = v),
                    ),
                    IconButton(
                      tooltip: tr('Graph map'),
                      icon: const Icon(Icons.multiline_chart),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => GraphDialog(session: widget.session),
                      ),
                    ),
                    IconButton(
                      tooltip: tr('Expressions'),
                      icon: const Icon(Icons.functions),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            ExpressionsDialog(session: widget.session),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed:
                          model.reading || model.rows.length >= maxRegisterRows
                          ? null
                          : edit,
                      icon: const Icon(Icons.add, size: 18),
                      label: const LText('Add row'),
                    ),
                    PopupMenuButton<String>(
                      tooltip: tr('CSV'),
                      enabled: !model.reading,
                      onSelected: (action) =>
                          action == 'import' ? csvImport() : csvExport(),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'import',
                          child: LText('Import CSV'),
                        ),
                        PopupMenuItem(
                          value: 'export',
                          child: LText('Export CSV'),
                        ),
                      ],
                      child: toolbarMenuLabel(
                        Icons.table_view_outlined,
                        'CSV',
                        enabled: !model.reading,
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: tr('Snapshot'),
                      onSelected: (action) {
                        if (action == 'capture') {
                          snapshot();
                        } else if (action == 'import' || action == 'export') {
                          snapshotFile(action == 'export');
                        } else {
                          final name = action.substring('compare:'.length);
                          final differences = model.diff(name).join('\n');
                          showText(
                            context,
                            trf('Snapshot {name} differences', {'name': name}),
                            differences.isEmpty
                                ? 'No differences'
                                : differences,
                          );
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'capture',
                          enabled: !model.reading,
                          child: const LText('Capture snapshot'),
                        ),
                        const PopupMenuItem(
                          value: 'import',
                          child: LText('Import snapshots'),
                        ),
                        const PopupMenuItem(
                          value: 'export',
                          child: LText('Export snapshots'),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          enabled: false,
                          child: LText('Compare snapshot'),
                        ),
                        for (final name in widget.session.snapshots.keys)
                          PopupMenuItem(
                            value: 'compare:$name',
                            child: Text(name),
                          ),
                      ],
                      child: toolbarMenuLabel(
                        Icons.photo_camera_outlined,
                        'Snapshot',
                      ),
                    ),
                    IconButton(
                      tooltip: tr('Select all / clear'),
                      onPressed: () => batch('all'),
                      icon: const Icon(Icons.select_all, size: 20),
                    ),
                    PopupMenuButton<String>(
                      tooltip: tr('Selected rows'),
                      enabled: !model.reading && hasSelection,
                      onSelected: batch,
                      itemBuilder: (_) => rowActions(),
                      child: toolbarMenuLabel(
                        Icons.playlist_add_check,
                        'Selected rows',
                        enabled: !model.reading && hasSelection,
                      ),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('enable-selected-polling'),
                      onPressed:
                          model.reading || widget.session.busy || !hasSelection
                          ? null
                          : () => batch('enable'),
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const LText('Enable polling'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('disable-selected-polling'),
                      onPressed:
                          model.reading || widget.session.busy || !hasSelection
                          ? null
                          : () => batch('disable'),
                      icon: const Icon(Icons.pause, size: 18),
                      label: const LText('Disable polling'),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 4,
                child: model.reading ? const LinearProgressIndicator() : null,
              ),
              if (message != null) LText(message!),
              if (widget.session.error != null)
                LText(widget.session.error!, maxLines: 2),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: filterBar(visible.length),
              ),
              const SizedBox(height: 8),
              Flexible(
                fit: widget.shrinkWrap ? FlexFit.loose : FlexFit.tight,
                child: DesktopTable(
                  shrinkWrap: widget.shrinkWrap,
                  compactByDefault: true,
                  columns: const [
                    TableColumnSpec('select', 'Select', 70),
                    TableColumnSpec('name', 'Name', 150),
                    TableColumnSpec('kind', 'Area', 160, hiddenByDefault: true),
                    TableColumnSpec('address', 'Address', 95),
                    TableColumnSpec('value', 'Value', 190),
                    TableColumnSpec('format', 'Format', 85),
                    TableColumnSpec(
                      'count',
                      'Count',
                      80,
                      hiddenByDefault: true,
                    ),
                    TableColumnSpec(
                      'unit_id',
                      'Unit',
                      80,
                      hiddenByDefault: true,
                    ),
                    TableColumnSpec('trend', 'Trend', 130),
                    TableColumnSpec('actions', 'Actions', 260),
                  ],
                  layout: desktopTableLayout(widget.session.draft, 'map_table'),
                  key: ValueKey(visible.join(',')),
                  rowCount: visible.length,
                  selected: (index) => selectedRows.contains(visible[index]),
                  selectionColumn: 'select',
                  onToggleRows: (indices) => setState(() {
                    for (final index in indices) {
                      final i = visible[index];
                      if (!selectedRows.add(i)) selectedRows.remove(i);
                    }
                  }),
                  onRowMenu: (index, position) =>
                      rowMenu(visible[index], position),
                  onRowTap: model.reading
                      ? null
                      : (index) => edit(visible[index]),
                  cellBuilder: (context, index, key) {
                    final i = visible[index];
                    final row = model.rows[i];
                    final result = i < model.results.length
                        ? model.results[i]
                        : null;
                    final writable =
                        row['kind'] == 'holding_registers' ||
                        row['kind'] == 'coils';
                    if (key == 'trend') {
                      final historyKey =
                          '${row['unit_id'] ?? widget.session.unit}/${row['kind']}/${row['address']}/${row['name']}';
                      final points =
                          widget.session.histories[historyKey]?.toList() ??
                          <Sample>[];
                      return row['trend_enabled'] == false || points.isEmpty
                          ? const Text('—')
                          : SizedBox(
                              height: 28,
                              child: CustomPaint(
                                painter: MultiSeriesPainter(
                                  [points],
                                  false,
                                  Theme.of(context).colorScheme,
                                  null,
                                ),
                              ),
                            );
                    }
                    if (key == 'select') {
                      return Tooltip(
                        message: tr('Click or drag to toggle row selection'),
                        child: Checkbox(
                          value: selectedRows.contains(i),
                          onChanged: (v) => setState(() {
                            if (v!) {
                              selectedRows.add(i);
                            } else {
                              selectedRows.remove(i);
                            }
                          }),
                        ),
                      );
                    }
                    if (key == 'actions') {
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (row['kind'] == 'holding_registers' &&
                                row['count'] == 1)
                              IconButton(
                                tooltip: tr('Edit bits'),
                                onPressed:
                                    !widget.session.canRead || model.reading
                                    ? null
                                    : () => write(i, bits: true),
                                icon: const Icon(Icons.grid_4x4, size: 18),
                              ),
                            if (hasInlineEnum(row))
                              inlineEnumEditor(
                                row,
                                result?['values'] as List? ?? [],
                                !writable ||
                                        !widget.session.canRead ||
                                        model.reading
                                    ? null
                                    : (v) => writeRaw(i, [v]),
                              )
                            else
                              IconButton(
                                tooltip: tr('Write row'),
                                onPressed:
                                    !writable ||
                                        !widget.session.canRead ||
                                        model.reading
                                    ? null
                                    : () => write(i),
                                icon: const Icon(Icons.edit_note),
                              ),
                            IconButton(
                              tooltip: tr('Delete row'),
                              onPressed: model.reading
                                  ? null
                                  : () {
                                      model.rows.removeAt(i);
                                      selectedRows.clear();
                                      model.changed();
                                    },
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      );
                    }
                    final text = key == 'value'
                        ? (result?['display'] ?? '—')
                        : key == 'unit_id'
                        ? row[key] ?? widget.session.unit
                        : row[key] ?? '';
                    if (key == 'name') {
                      final paused = row['poll_enabled'] == false;
                      return Tooltip(
                        message: paused
                            ? '${tr('$text')}\n${tr('Polling disabled; right-click to enable')}'
                            : tr('$text'),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 20,
                              child: paused
                                  ? ExcludeSemantics(
                                      child: Icon(
                                        Icons.pause_circle_outline,
                                        size: 16,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                    )
                                  : null,
                            ),
                            Expanded(
                              child: LText(
                                '$text',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: paused
                                    ? TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      )
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    return Tooltip(
                      message: tr('$text'),
                      child: LText(
                        '$text',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: key != 'value' || result?['alarm'] == null
                            ? null
                            : TextStyle(
                                color: result!['alarm']['color'] == 'yellow'
                                    ? Colors.amber.shade800
                                    : Colors.red,
                              ),
                      ),
                    );
                  },
                ),
              ),
              if (model.rows.isEmpty)
                const LText(
                  'Add named rows at any unit/address, or import a CSV/template.',
                ),
              if (model.rows.isNotEmpty && visible.isEmpty)
                const LText('No registers match the filters.'),
            ],
          ),
        ),
      );
    },
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
  late List<Map<String, dynamic>> alarms =
      (widget.row?['alarms'] as List? ?? []).cast<Map<String, dynamic>>();
  @override
  void initState() {
    super.initState();
    for (final e in {
      'name': tr('Register'),
      'address': 0,
      'count': 1,
      'unit_id': '',
      'poll_ms': '',
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
    final pollMs = fields['poll_ms']!.text.trim().isEmpty
        ? null
        : int.tryParse(fields['poll_ms']!.text);
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
        (fields['poll_ms']!.text.isNotEmpty &&
            (pollMs == null || pollMs < 100 || pollMs > 86400000)) ||
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
      'poll_ms': pollMs,
      'format': format,
      'order': order,
      'scale': scale,
      'offset': offset,
      'unit': fields['unit']!.text,
      'value_names': names,
      'bitmask': bitmask,
      'alarms': alarms,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const LText('Register row'),
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
                for (final key in ['address', 'count', 'unit_id', 'poll_ms'])
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
            TextButton(
              onPressed: () async {
                final edited = await showDialog<List<Map<String, dynamic>>>(
                  context: context,
                  builder: (_) => AlarmRulesDialog(rules: alarms),
                );
                if (edited != null && mounted) setState(() => alarms = edited);
              },
              child: LText('Alarm rules (${alarms.length})'),
            ),
            CheckboxListTile(
              title: const LText('Names label bits 0–15'),
              value: bitmask,
              onChanged: (v) => setState(() => bitmask = v!),
            ),
            if (error != null) LText(error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const LText('Cancel'),
      ),
      FilledButton(onPressed: save, child: const LText('Apply')),
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
    title: LText('Bits · 0x${value.toRadixString(16).padLeft(4, '0')}'),
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
              title: LText('b$bit ${widget.names['$bit'] ?? ''}'),
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
        child: const LText('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, value),
        child: const LText('Write'),
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
    title: const LText('CSV column mapping'),
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
                  Expanded(child: LText(column)),
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
        child: const LText('Cancel'),
      ),
      FilledButton(
        onPressed: ['name', 'kind', 'address'].every(mapping.values.contains)
            ? () => Navigator.pop(context, mapping)
            : null,
        child: const LText('Import'),
      ),
    ],
  );
}

/// Enum choices and bit toggles use raw words, independent of display scaling.
bool hasRawEditor(Map<String, dynamic> row) =>
    row['count'] == 1 &&
    (['coils', 'discrete_inputs'].contains(row['kind']) ||
        ['dec', 's16', 'hex'].contains(row['format'])) &&
    (row['bitmask'] == true || (row['value_names'] as Map? ?? {}).isNotEmpty);

Future<List<dynamic>?> rawValuePrompt(
  BuildContext context,
  Map<String, dynamic> row,
  List raw,
) async {
  final names = (row['value_names'] as Map? ?? {}).cast<String, dynamic>();
  if (row['bitmask'] == true &&
      !['coils', 'discrete_inputs'].contains(row['kind'])) {
    final value = await showDialog<int>(
      context: context,
      builder: (_) => BitsDialog(
        value: raw.isEmpty ? 0 : (raw.first as num).toInt(),
        names: names,
      ),
    );
    return value == null ? null : [value];
  }
  final value = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: LText(row['name'] as String? ?? 'Set value'),
      children: [
        for (final entry in names.entries)
          if (int.tryParse(entry.key) != null &&
              int.parse(entry.key) >= 0 &&
              int.parse(entry.key) <=
                  (['coils', 'discrete_inputs'].contains(row['kind'])
                      ? 1
                      : 65535))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, int.parse(entry.key)),
              child: Text('${entry.key} = ${entry.value}'),
            ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const LText('Cancel'),
        ),
      ],
    ),
  );
  return value == null ? null : [value];
}

bool hasInlineEnum(Map<String, dynamic> row) =>
    hasRawEditor(row) && row['bitmask'] != true;

Widget inlineEnumEditor(
  Map<String, dynamic> row,
  List raw,
  ValueChanged<int>? changed,
) {
  final names = (row['value_names'] as Map).cast<String, dynamic>();
  final keys = names.keys
      .map(int.tryParse)
      .whereType<int>()
      .where(
        (v) =>
            v >= 0 &&
            v <=
                (['coils', 'discrete_inputs'].contains(row['kind'])
                    ? 1
                    : 65535),
      )
      .toList();
  final current = raw.isEmpty
      ? null
      : raw.first is bool
      ? (raw.first == true ? 1 : 0)
      : (raw.first as num).toInt();
  return SizedBox(
    width: 135,
    child: DropdownButton<int>(
      isExpanded: true,
      value: keys.contains(current) ? current : null,
      hint: const LText('Set value'),
      items: [
        for (final key in keys)
          DropdownMenuItem(
            value: key,
            child: Text(
              '$key = ${names['$key']}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: changed == null
          ? null
          : (v) {
              if (v != null) changed(v);
            },
    ),
  );
}

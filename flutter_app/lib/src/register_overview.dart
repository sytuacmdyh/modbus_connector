import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'backend/registers.dart' as registers;
import 'logging_dialog.dart';
import 'session_controller.dart';
import 'tool_widgets.dart';
import 'translations.dart';

const overviewSettingsKey = 'map_overview';
const overviewRowIdKey = 'overview_id';

List<Map<String, dynamic>> overviewBlocks(SessionController session) {
  final saved = session.draft[overviewSettingsKey];
  if (saved is Map && saved['blocks'] is List) {
    return [
      for (final block in saved['blocks'] as List)
        if (block is Map) Map<String, dynamic>.from(block),
    ];
  }
  return [
    {
      'name': 'Registers',
      'enabled': true,
      'items': [
        for (var i = 0; i < session.registers.length; i++) {'row': i},
      ],
    },
  ];
}

/// Uses the map's published results only; never owns a connection or timer.
class RegisterOverview extends StatelessWidget {
  const RegisterOverview({
    super.key,
    required this.session,
    required this.onConfigure,
  });
  final SessionController session;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final rows = session.registers;
    final indices = {
      for (var i = 0; i < rows.length; i++)
        if (rows[i][overviewRowIdKey] is String) rows[i][overviewRowIdKey]: i,
    };
    final lines = <Widget Function()>[];
    for (final block in overviewBlocks(session)) {
      if (block['enabled'] == false) continue;
      final items = <(int, Map<String, dynamic>)>[];
      for (final raw in block['items'] as List? ?? []) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final index = item['row_id'] == null
            ? item['row']
            : indices[item['row_id']];
        if (index is int && index >= 0 && index < rows.length) {
          items.add((index, item));
        }
      }
      lines.add(
        () => Container(
          key: ValueKey('overview-block-${block['name']}'),
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Text(
            tr('${block['name'] ?? 'Registers'}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      );
      if (items.isEmpty) {
        lines.add(
          () => const Padding(
            padding: EdgeInsets.all(8),
            child: LText('No registers selected'),
          ),
        );
      }
      // The sliver builds pairs on demand, including maps with thousands of rows.
      for (var i = 0; i < items.length; i += 2) {
        final pair = items.skip(i).take(2).toList();
        lines.add(
          () => LayoutBuilder(
            builder: (context, constraints) {
              final cells = [
                for (final (index, item) in pair)
                  _OverviewValue(session: session, index: index, item: item),
              ];
              return constraints.maxWidth < 320
                  ? Column(children: cells)
                  : Row(
                      children: [
                        for (final cell in cells) Expanded(child: cell),
                        if (cells.length == 1) const Spacer(),
                      ],
                    );
            },
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 36,
          child: Row(
            children: [
              const Expanded(
                child: LText(
                  'Overview',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Flexible(
                child: TextButton(
                  key: const ValueKey('overview-configure'),
                  onPressed: onConfigure,
                  child: const LText(
                    'Configure display',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: lines.isEmpty
              ? const Center(
                  child: LText(
                    'Configure overview blocks to display registers.',
                  ),
                )
              : ListView.builder(
                  key: const ValueKey('register-overview-list'),
                  padding: EdgeInsets.zero,
                  itemCount: lines.length,
                  itemBuilder: (_, i) => lines[i](),
                ),
        ),
      ],
    );
  }
}

class _OverviewValue extends StatelessWidget {
  const _OverviewValue({
    required this.session,
    required this.index,
    required this.item,
  });
  final SessionController session;
  final int index;
  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final row = session.registers[index];
    final result = index < session.registerResults.length
        ? session.registerResults[index]
        : null;
    final valid =
        result != null && result['error'] == null && result['values'] is List;
    final numeric = valid ? result['numeric'] : null;
    final rule = item.containsKey('rules')
        ? registers.alarm(numeric is num ? numeric : null, item['rules'])
        : valid
        ? result['alarm']
        : null;
    final colors = Theme.of(context).colorScheme;
    final color = !valid
        ? colors.onSurfaceVariant
        : rule != null
        ? rule['color'] == 'yellow'
              ? Colors.amber.shade800
              : colors.error
        : colors.primary;
    final name = tr('${item['label'] ?? row['name'] ?? ''}');
    final text = valid ? '${result['display'] ?? '—'}' : '—';
    final unit = '${row['unit'] ?? ''}';
    final hasUnit = unit.isNotEmpty && text.endsWith(' $unit');
    final value = hasUnit
        ? text.substring(0, text.length - unit.length - 1)
        : text;
    final status = !valid
        ? (result?['error']?.toString() ?? tr('No data'))
        : (rule != null ? tr('Warning') : '');
    return Tooltip(
      message:
          '$name · ${row['address']}\n$text${status.isEmpty ? '' : '\n$status'}',
      child: Container(
        key: ValueKey('overview-value-$index'),
        constraints: const BoxConstraints(minHeight: 30),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .5),
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (hasUnit)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 3),
                  child: Text(
                    unit,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            if (rule != null)
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Text(
                  '!',
                  semanticsLabel: tr('Warning'),
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class OverviewConfigDialog extends StatefulWidget {
  const OverviewConfigDialog({super.key, required this.session});
  final SessionController session;
  @override
  State<OverviewConfigDialog> createState() => _OverviewConfigDialogState();
}

class _OverviewConfigDialogState extends State<OverviewConfigDialog> {
  late final rows = widget.session.registers.toList();
  late final ids = [
    for (final row in rows)
      row[overviewRowIdKey] is String ? row[overviewRowIdKey] as String : _id(),
  ];
  late final blocks = _loadBlocks();
  final search = TextEditingController();
  int selected = 0;
  String? error;

  String _id() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  List<Map<String, dynamic>> _loadBlocks() {
    final copy = (jsonDecode(
      jsonEncode(overviewBlocks(widget.session)),
    ) as List).cast<Map<String, dynamic>>();
    for (final block in copy) {
      block['items'] = [
        for (final raw in block['items'] as List? ?? [])
          if (raw is Map)
            if (raw['row_id'] is String)
              Map<String, dynamic>.from(raw)
            else if (raw['row'] is int &&
                raw['row'] >= 0 &&
                raw['row'] < ids.length)
              {
                ...Map<String, dynamic>.from(raw)..remove('row'),
                'row_id': ids[raw['row']],
              },
      ];
    }
    return copy;
  }

  List<Map<String, dynamic>> get items =>
      (blocks[selected]['items'] as List).cast<Map<String, dynamic>>();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> nameBlock({bool add = false}) async {
    final name = await textPrompt(
      context,
      add ? 'New overview block' : 'Block name',
      value: add ? '' : '${blocks[selected]['name']}',
    );
    if (!mounted || name == null || name.trim().isEmpty) return;
    setState(() {
      if (add) {
        blocks.add({
          'name': name.trim(),
          'enabled': true,
          'items': <Map<String, dynamic>>[],
        });
        selected = blocks.length - 1;
      } else {
        blocks[selected]['name'] = name.trim();
      }
    });
  }

  void apply() {
    if (rows.length != widget.session.registers.length ||
        List.generate(
          rows.length,
          (i) => identical(rows[i], widget.session.registers[i]),
        ).contains(false)) {
      setState(() => error = 'Register map changed; reopen configuration.');
      return;
    }
    for (var i = 0; i < rows.length; i++) {
      rows[i][overviewRowIdKey] = ids[i];
    }
    widget.session.draft[overviewSettingsKey] = {'blocks': blocks};
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (var i = 0; i < rows.length; i++)
        if (tr('${rows[i]['name'] ?? ''}')
            .toLowerCase()
            .contains(search.text.toLowerCase()))
          i,
    ];
    return AlertDialog(
      title: const LText('Configure overview'),
      content: SizedBox(
        width: 760,
        height: 480,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButton<int>(
                    key: const ValueKey('overview-block-select'),
                    isExpanded: true,
                    value: blocks.isEmpty ? null : selected,
                    hint: const LText('No blocks'),
                    items: [
                      for (var i = 0; i < blocks.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(tr('${blocks[i]['name']}')),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => selected = v);
                    },
                  ),
                ),
                TextButton(
                  onPressed: () => nameBlock(add: true),
                  child: const LText('Add block'),
                ),
                if (blocks.isNotEmpty) ...[
                  TextButton(
                    onPressed: nameBlock,
                    child: const LText('Rename'),
                  ),
                  IconButton(
                    tooltip: tr('Move up'),
                    onPressed: selected == 0
                        ? null
                        : () => setState(() {
                            final block = blocks.removeAt(selected);
                            blocks.insert(--selected, block);
                          }),
                    icon: const Icon(Icons.arrow_upward, size: 16),
                  ),
                  IconButton(
                    tooltip: tr('Remove block'),
                    onPressed: () => setState(() {
                      blocks.removeAt(selected);
                      selected = max(0, selected - 1);
                    }),
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ],
            ),
            if (blocks.isNotEmpty) ...[
              Row(
                children: [
                  Checkbox(
                    value: blocks[selected]['enabled'] != false,
                    onChanged: (v) =>
                        setState(() => blocks[selected]['enabled'] = v),
                  ),
                  const LText('Show block'),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () => setState(() {
                      blocks[selected]['items'] = [
                        ...items,
                        for (final i in visible)
                          if (!items.any((item) => item['row_id'] == ids[i]))
                            {'row_id': ids[i]},
                      ];
                    }),
                    child: const LText('Select all'),
                  ),
                  TextButton(
                    onPressed: () => setState(
                      () =>
                          blocks[selected]['items'] = <Map<String, dynamic>>[],
                    ),
                    child: const LText('Clear selection'),
                  ),
                ],
              ),
              TextField(
                controller: search,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr('Filter by name'),
                ),
                onChanged: (_) => setState(() {}),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, at) {
                    final i = visible[at], row = rows[i];
                    final item = items
                        .where((entry) => entry['row_id'] == ids[i])
                        .firstOrNull;
                    return Row(
                      children: [
                        Expanded(
                          child: CheckboxListTile(
                            key: ValueKey('overview-select-$i'),
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(
                              tr('${row['name'] ?? ''}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${row['unit_id'] ?? widget.session.unit} / ${row['kind']} / ${row['address']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            value: item != null,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                items.add({'row_id': ids[i]});
                              } else {
                                items.removeWhere(
                                  (entry) => entry['row_id'] == ids[i],
                                );
                              }
                            }),
                          ),
                        ),
                        TextButton(
                          key: ValueKey('overview-rules-$i'),
                          onPressed: item == null
                              ? null
                              : () async {
                                  final edited =
                                      await showDialog<
                                        List<Map<String, dynamic>>
                                      >(
                                        context: context,
                                        builder: (_) => AlarmRulesDialog(
                                          displayOnly: true,
                                          rules: [
                                            for (final rule
                                                in item['rules'] as List? ??
                                                    row['alarms'] as List? ??
                                                    [])
                                              if (rule is Map)
                                                Map<String, dynamic>.from(rule),
                                          ],
                                        ),
                                      );
                                  if (edited != null && mounted) {
                                    setState(() => item['rules'] = edited);
                                  }
                                },
                          child: const LText('Value colors'),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ] else
              const Expanded(
                child: Center(child: LText('Add a block to select registers.')),
              ),
            if (error != null) LText(error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const LText('Cancel'),
        ),
        FilledButton(onPressed: apply, child: const LText('Apply')),
      ],
    );
  }
}

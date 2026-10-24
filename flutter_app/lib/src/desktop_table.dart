import 'package:flutter/material.dart';

import 'translations.dart';

Map<String, dynamic> desktopTableLayout(
  Map<String, dynamic> draft,
  String key,
) {
  if (draft[key] is! Map<String, dynamic>) draft[key] = <String, dynamic>{};
  return draft[key] as Map<String, dynamic>;
}

class TableColumnSpec {
  const TableColumnSpec(this.key, this.label, this.width);
  final String key;
  final String label;
  final double width;
}

/// Lazy rows, a shared horizontal viewport and stable, persisted column IDs.
class DesktopTable extends StatefulWidget {
  const DesktopTable({
    super.key,
    required this.columns,
    required this.layout,
    required this.rowCount,
    required this.cellBuilder,
    this.onRowTap,
    this.onRowMenu,
    this.selected,
    this.shrinkWrap = false,
  });
  final List<TableColumnSpec> columns;
  final Map<String, dynamic> layout;
  final int rowCount;
  final Widget Function(BuildContext, int, String) cellBuilder;
  final ValueChanged<int>? onRowTap;
  final void Function(int, Offset)? onRowMenu;
  final bool Function(int)? selected;

  /// Size short tables to their rows; cap the scrolling body for long maps.
  final bool shrinkWrap;
  @override
  State<DesktopTable> createState() => _DesktopTableState();
}

class _DesktopTableState extends State<DesktopTable> {
  final horizontal = ScrollController();
  final vertical = ScrollController();
  List<String> get order {
    final keys = widget.columns.map((c) => c.key).toList();
    final saved = widget.layout['order'];
    return {
      if (saved is List) ...saved.whereType<String>().where(keys.contains),
      ...keys,
    }.toList();
  }

  List<String> get visible {
    final hidden = widget.layout['hidden'];
    final keys = order
        .where((k) => hidden is! List || !hidden.contains(k))
        .toList();
    // A damaged or old workspace must never leave an inaccessible empty table.
    return keys.isEmpty ? order : keys;
  }

  void toggleColumn(String key) => setState(() {
    final hidden = <String>{
      if (widget.layout['hidden'] is List)
        ...(widget.layout['hidden'] as List).whereType<String>(),
    };
    if (hidden.contains(key)) {
      hidden.remove(key);
    } else if (visible.length > 1) {
      hidden.add(key);
    }
    widget.layout['hidden'] = hidden.toList();
  });

  double width(String key) {
    final widths = widget.layout['widths'];
    final value = widths is Map ? widths[key] : null;
    return value is num && value.isFinite
        ? value.toDouble().clamp(64, 600)
        : widget.columns.firstWhere((c) => c.key == key).width;
  }

  void move(String from, String to) => setState(() {
    final keys = order;
    final target = keys.indexOf(to);
    keys.remove(from);
    keys.insert(target, from);
    widget.layout['order'] = keys;
  });

  @override
  void dispose() {
    horizontal.dispose();
    vertical.dispose();
    super.dispose();
  }

  Widget header(String key) {
    final spec = widget.columns.firstWhere((c) => c.key == key);
    return DragTarget<String>(
      key: ValueKey('column-$key'),
      onWillAcceptWithDetails: (d) => d.data != key && order.contains(d.data),
      onAcceptWithDetails: (d) => move(d.data, key),
      builder: (context, candidates, _) => Container(
        width: width(key),
        color: candidates.isEmpty
            ? null
            : Theme.of(context).colorScheme.primaryContainer,
        child: Row(
          children: [
            Expanded(
              child: Draggable<String>(
                data: key,
                feedback: Material(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: LText(spec.label),
                  ),
                ),
                child: PopupMenuButton<String>(
                  tooltip: tr('Drag to reorder; drag edge to resize'),
                  onSelected: (action) {
                    final keys = order;
                    final at = keys.indexOf(key);
                    if (action == 'reset') {
                      setState(widget.layout.clear);
                    } else if (action.startsWith('column:')) {
                      toggleColumn(action.substring(7));
                    } else if (action == 'compact') {
                      setState(
                        () => widget.layout['compact'] =
                            widget.layout['compact'] != true,
                      );
                    } else if (action == 'left' && at > 0) {
                      move(key, keys[at - 1]);
                    } else if (action == 'right' && at < keys.length - 1) {
                      move(key, keys[at + 1]);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'left',
                      child: LText('Move column left'),
                    ),
                    const PopupMenuItem(
                      value: 'right',
                      child: LText('Move column right'),
                    ),
                    const PopupMenuDivider(),
                    for (final column in widget.columns)
                      CheckedPopupMenuItem(
                        value: 'column:${column.key}',
                        checked: visible.contains(column.key),
                        enabled:
                            !visible.contains(column.key) || visible.length > 1,
                        child: LText(column.label),
                      ),
                    const PopupMenuDivider(),
                    CheckedPopupMenuItem(
                      value: 'compact',
                      checked: widget.layout['compact'] == true,
                      child: const LText('Compact rows'),
                    ),
                    const PopupMenuItem(
                      value: 'reset',
                      child: LText('Reset columns'),
                    ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: LText(
                      spec.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                key: ValueKey('resize-$key'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => setState(() {
                  final widths = Map<String, dynamic>.from(
                    widget.layout['widths'] is Map
                        ? widget.layout['widths'] as Map
                        : {},
                  );
                  widths[key] = (width(key) + d.delta.dx).clamp(64, 600);
                  widget.layout['widths'] = widths;
                }),
                child: const SizedBox(
                  width: 10,
                  height: 40,
                  child: VerticalDivider(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final keys = visible;
      final total = keys.fold<double>(0, (sum, key) => sum + width(key));
      final rowHeight =
          (widget.layout['compact'] == true ? 48.0 : 56.0) *
          MediaQuery.textScalerOf(context).scale(1).clamp(1, 2);
      final body = Scrollbar(
        controller: vertical,
        thumbVisibility: true,
        child: ListView.builder(
          controller: vertical,
          primary: false,
          padding: const EdgeInsets.only(bottom: 14),
          itemCount: widget.rowCount,
          itemExtent: rowHeight,
          itemBuilder: (context, i) => GestureDetector(
            onSecondaryTapDown: (d) =>
                widget.onRowMenu?.call(i, d.globalPosition),
            child: Material(
              color: widget.selected?.call(i) == true
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Colors.transparent,
              child: InkWell(
                onTap: widget.onRowTap == null
                    ? null
                    : () => widget.onRowTap!(i),
                child: Row(
                  children: [
                    for (final key in keys)
                      SizedBox(
                        width: width(key),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: widget.cellBuilder(context, i, key),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      return Scrollbar(
        controller: horizontal,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: horizontal,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: total < constraints.maxWidth ? constraints.maxWidth : total,
            height: widget.shrinkWrap ? null : constraints.maxHeight,
            child: Column(
              mainAxisSize: widget.shrinkWrap
                  ? MainAxisSize.min
                  : MainAxisSize.max,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Row(children: keys.map(header).toList()),
                ),
                if (widget.shrinkWrap)
                  SizedBox(
                    height: (widget.rowCount * rowHeight + 14)
                        .clamp(14, 320)
                        .toDouble(),
                    child: body,
                  )
                else
                  Expanded(child: body),
              ],
            ),
          ),
        ),
      );
    },
  );
}

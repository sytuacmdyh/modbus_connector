import 'file_paths.dart';
import 'translations.dart';

import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'session_controller.dart';
import 'tool_widgets.dart';
import 'graph_window_host.dart';

const curveColors = [
  Colors.teal,
  Colors.orange,
  Colors.blue,
  Colors.purple,
  Colors.red,
  Colors.green,
  Colors.pink,
  Colors.brown,
];

Sample? nearestGraphSample(List<Sample> samples, DateTime time) {
  if (samples.isEmpty) return null;
  return samples.reduce(
    (a, b) =>
        a.time.difference(time).abs() <= b.time.difference(time).abs() ? a : b,
  );
}

class GraphDialog extends StatefulWidget {
  const GraphDialog({
    super.key,
    required this.session,
    this.historyPrefix,
    this.detached = false,
    this.onViewerCommand,
  });
  final SessionController session;
  final String? historyPrefix;
  final bool detached;
  final ValueChanged<Map<String, dynamic>>? onViewerCommand;
  @override
  State<GraphDialog> createState() => _GraphDialogState();
}

class _GraphDialogState extends State<GraphDialog> {
  Iterable<String> get availableKeys => widget.session.histories.keys.where(
    (k) => widget.historyPrefix == null || k.startsWith(widget.historyPrefix!),
  );
  final selected = <String>{};
  bool normalized = false;
  bool paused = false;
  int seconds = 60;
  Map<String, List<Sample>>? frozen;
  double? hover;
  bool pinned = false;
  DateTime? pinnedTime;
  final chartKey = GlobalKey();
  final transform = TransformationController();
  String get settingsKey => 'graph:${widget.historyPrefix ?? 'master'}';
  bool selectionReady = false;
  void saveSettings() {
    final data = {
      'selected': selected.toList(),
      'seconds': seconds,
      'normalized': normalized,
    };
    widget.session.draft[settingsKey] = data;
    widget.onViewerCommand?.call({
      'selected': selected.toList(),
      'settings': data,
    });
  }

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  Future<void> exportPng() async {
    final path = await chooseFilePath(
      context,
      save: true,
      title: 'Export graph PNG file path',
      extension: 'png',
      suggestedName: 'graph.png',
    );
    if (path == null || path.isEmpty || !mounted) return;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final boundary =
          chartKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      } finally {
        image.dispose();
      }
      if (mounted) setState(() => message = '${tr('Saved')} $path');
    } catch (e) {
      if (mounted) {
        setState(
          () => message = '${tr('Image export failed')}: ${userError(e)}',
        );
      }
    }
  }

  String? message;
  @override
  void initState() {
    super.initState();
    final saved = widget.session.draft[settingsKey];
    if (saved is Map) {
      if (saved['selected'] is List) {
        selected.addAll((saved['selected'] as List).whereType<String>());
        selectionReady = true;
      }
      if ([10, 30, 60, 300, 3600].contains(saved['seconds'])) {
        seconds = saved['seconds'] as int;
      }
      normalized = saved['normalized'] == true;
    }
    if (!selectionReady && availableKeys.isNotEmpty) {
      selected.addAll(availableKeys.take(4));
      selectionReady = true;
    }
  }

  Map<String, List<Sample>> series() {
    final source = paused
        ? frozen ?? {}
        : widget.session.histories.map((k, v) => MapEntry(k, v.toList()));
    final all = availableKeys.expand((key) => source[key] ?? <Sample>[]);
    final last = all.isEmpty
        ? DateTime.now()
        : all.map((s) => s.time).reduce((a, b) => a.isAfter(b) ? a : b);
    return {
      for (final key in selected)
        key: (source[key] ?? [])
            .where(
              (s) => s.time.isAfter(last.subtract(Duration(seconds: seconds))),
            )
            .toList(),
    };
  }

  Future<void> export() async {
    final path = await chooseFilePath(
      context,
      save: true,
      title: 'Export graph samples CSV file path',
      extension: 'csv',
      suggestedName: 'graph.csv',
    );
    if (path == null || path.isEmpty) return;
    try {
      final buffer = StringBuffer('timestamp,series,value\n');
      for (final e in series().entries) {
        final label = (widget.session.historyLabels[e.key] ?? e.key).replaceAll(
          '"',
          '""',
        );
        for (final sample in e.value) {
          buffer.writeln(
            '${sample.time.toIso8601String()},"$label",${sample.value}',
          );
        }
      }
      await File(path).writeAsString(buffer.toString(), flush: true);
      if (mounted) setState(() => message = '${tr('Saved')} $path');
    } catch (e) {
      if (mounted) setState(() => message = userError(e));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, appLanguage]),
    builder: (context, _) {
      if (!selectionReady && availableKeys.isNotEmpty) {
        selected.addAll(availableKeys.take(4));
        selectionReady = true;
      }
      if (selectionReady) saveSettings();
      final curves = series();
      final points = curves.values.expand((v) => v).toList();
      final first = points.isEmpty
          ? DateTime.now()
          : points.map((p) => p.time).reduce((a, b) => a.isBefore(b) ? a : b);
      final last = points.isEmpty
          ? first
          : points.map((p) => p.time).reduce((a, b) => a.isAfter(b) ? a : b);
      final cursor = pinnedTime == null
          ? hover
          : ((pinnedTime!.microsecondsSinceEpoch -
                        first.microsecondsSinceEpoch) /
                    math.max(
                      1,
                      last.microsecondsSinceEpoch -
                          first.microsecondsSinceEpoch,
                    ))
                .clamp(0.0, 1.0);
      return AlertDialog(
        scrollable: true,
        title: const LText('Multi-series graph'),
        content: SizedBox(
          width: 800,
          height: 520 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
          child: Column(
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  toolChoice(
                    'Time window, s',
                    '$seconds',
                    ['10', '30', '60', '300', '3600'],
                    (v) => setState(() => seconds = int.parse(v)),
                    width: 155,
                  ),
                  FilterChip(
                    label: const LText('Normalize each curve'),
                    selected: normalized,
                    onSelected: (v) => setState(() => normalized = v),
                  ),
                  FilterChip(
                    label: LText(paused ? 'Resume chart' : 'Pause chart'),
                    selected: paused,
                    onSelected: (v) => setState(() {
                      paused = v;
                      frozen = widget.session.histories.map(
                        (k, v) => MapEntry(k, v.toList()),
                      );
                    }),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      transform.value = Matrix4.identity();
                    }),
                    child: const LText('Reset zoom'),
                  ),
                  if (!widget.detached)
                    TextButton(
                      onPressed: () async {
                        try {
                          await GraphWindowHost.open(
                            widget.session,
                            prefix: widget.historyPrefix,
                          );
                          if (context.mounted) Navigator.pop(context);
                        } catch (e) {
                          if (mounted) setState(() => message = userError(e));
                        }
                      },
                      child: const LText('Open separate window'),
                    ),
                  TextButton(
                    onPressed: export,
                    child: const LText('Export samples'),
                  ),
                  TextButton(
                    onPressed: exportPng,
                    child: const LText('Export PNG'),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      if (widget.detached) {
                        widget.onViewerCommand?.call({'clear': true});
                      }
                      for (final key in availableKeys.toList()) {
                        widget.session.histories[key]?.clear();
                      }
                    }),
                    child: const LText('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: RepaintBoundary(
                  key: chartKey,
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 205,
                          child: ListView(
                            children: [
                              for (final key in availableKeys)
                                CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: LText(
                                    widget.session.historyLabels[key] ?? key,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  value: selected.contains(key),
                                  onChanged: (v) => setState(() {
                                    if (v!) {
                                      selected.add(key);
                                    } else {
                                      selected.remove(key);
                                    }
                                  }),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, bounds) => MouseRegion(
                                    onHover: (e) {
                                      if (!pinned) {
                                        setState(
                                          () => hover =
                                              (transform
                                                          .toScene(
                                                            e.localPosition,
                                                          )
                                                          .dx /
                                                      bounds.maxWidth)
                                                  .clamp(0, 1),
                                        );
                                      }
                                    },
                                    onExit: (_) {
                                      if (!pinned) setState(() => hover = null);
                                    },
                                    child: ClipRect(
                                      child: GestureDetector(
                                        onTapDown: (e) => setState(() {
                                          pinned = !pinned;
                                          hover =
                                              (transform
                                                          .toScene(
                                                            e.localPosition,
                                                          )
                                                          .dx /
                                                      bounds.maxWidth)
                                                  .clamp(0, 1);
                                          pinnedTime = pinned
                                              ? DateTime.fromMicrosecondsSinceEpoch(
                                                  first.microsecondsSinceEpoch +
                                                      ((last.microsecondsSinceEpoch -
                                                                  first
                                                                      .microsecondsSinceEpoch) *
                                                              cursor!)
                                                          .round(),
                                                )
                                              : null;
                                        }),
                                        child: InteractiveViewer(
                                          transformationController: transform,
                                          minScale: 1,
                                          maxScale: 10,
                                          child: CustomPaint(
                                            painter: MultiSeriesPainter(
                                              curves.values.toList(),
                                              normalized,
                                              Theme.of(context).colorScheme,
                                              cursor,
                                            ),
                                            size: Size.infinite,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  LText(
                                    first.toIso8601String().substring(11, 19),
                                  ),
                                  LText(
                                    last.toIso8601String().substring(11, 19),
                                  ),
                                ],
                              ),
                              SizedBox(
                                height: 100,
                                child: ListView(
                                  children: [
                                    for (var i = 0; i < curves.length; i++)
                                      Builder(
                                        builder: (context) {
                                          final key = curves.keys.elementAt(i);
                                          final samples = curves[key]!;
                                          final values = samples
                                              .map((s) => s.value)
                                              .toList();
                                          final target =
                                              DateTime.fromMicrosecondsSinceEpoch(
                                                first.microsecondsSinceEpoch +
                                                    ((last.microsecondsSinceEpoch -
                                                                first
                                                                    .microsecondsSinceEpoch) *
                                                            (cursor ?? 1))
                                                        .round(),
                                              );
                                          final sample = nearestGraphSample(
                                            samples,
                                            target,
                                          );
                                          final at = sample?.value;
                                          return LText(
                                            '${tr(widget.session.historyLabels[key] ?? key)}: ${at?.toStringAsPrecision(6) ?? '—'}   ${values.isEmpty ? '' : '${tr('min')} ${values.reduce(math.min).toStringAsPrecision(4)} / ${tr('max')} ${values.reduce(math.max).toStringAsPrecision(4)} / ${tr('mean')} ${(values.reduce((a, b) => a + b) / values.length).toStringAsPrecision(4)}'}',
                                            style: TextStyle(
                                              color:
                                                  curveColors[i %
                                                      curveColors.length],
                                              fontSize: 12,
                                            ),
                                          );
                                        },
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (cursor != null)
                LText(
                  DateTime.fromMicrosecondsSinceEpoch(
                    first.microsecondsSinceEpoch +
                        ((last.microsecondsSinceEpoch -
                                    first.microsecondsSinceEpoch) *
                                cursor)
                            .round(),
                  ).toIso8601String(),
                ),
              const LText(
                'Click to pin a sample; click again to follow the pointer.',
              ),
              if (points.isEmpty)
                const LText(
                  'Read or poll a range/map to collect samples. Sniffer traffic also adds curves.',
                ),
              if (message != null) LText(message!),
              const LText(
                'Scroll/pinch to zoom; drag to pan. Up to 1000 samples per series, sampled at most 10 Hz.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (widget.detached) {
                exit(0);
              } else {
                Navigator.pop(context);
              }
            },
            child: const LText('Close'),
          ),
        ],
      );
    },
  );
}

class MultiSeriesPainter extends CustomPainter {
  MultiSeriesPainter(this.series, this.normalized, this.colors, this.hover);
  final List<List<Sample>> series;
  final bool normalized;
  final ColorScheme colors;
  final double? hover;
  @override
  void paint(Canvas canvas, Size size) {
    final points = series.expand((s) => s).toList();
    if (points.isEmpty) return;
    final first = points
        .map((p) => p.time.millisecondsSinceEpoch)
        .reduce(math.min);
    final last = points
        .map((p) => p.time.millisecondsSinceEpoch)
        .reduce(math.max);
    final globalMin = points.map((p) => p.value).reduce(math.min);
    final globalMax = points.map((p) => p.value).reduce(math.max);
    for (var i = 0; i <= 4; i++) {
      canvas.drawLine(
        Offset(0, size.height * i / 4),
        Offset(size.width, size.height * i / 4),
        Paint()
          ..color = colors.outlineVariant
          ..strokeWidth = 0.5,
      );
    }
    for (var i = 0; i < series.length; i++) {
      final samples = series[i];
      if (samples.isEmpty) continue;
      final low = normalized
          ? samples.map((s) => s.value).reduce(math.min)
          : globalMin;
      final high = normalized
          ? samples.map((s) => s.value).reduce(math.max)
          : globalMax;
      final pad = math.max((high - low) * 0.05, 0.01);
      final path = Path();
      for (var j = 0; j < samples.length; j++) {
        final p = Offset(
          (samples[j].time.millisecondsSinceEpoch - first) /
              math.max(1, last - first) *
              size.width,
          size.height *
              (1 - (samples[j].value - low + pad) / (high - low + 2 * pad)),
        );
        if (j == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
        if (samples.length == 1) {
          canvas.drawCircle(
            p,
            3,
            Paint()..color = curveColors[i % curveColors.length],
          );
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = curveColors[i % curveColors.length]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..isAntiAlias = true,
      );
    }
    if (hover != null) {
      canvas.drawLine(
        Offset(size.width * hover!, 0),
        Offset(size.width * hover!, size.height),
        Paint()
          ..color = colors.onSurface.withValues(alpha: 0.5)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant MultiSeriesPainter oldDelegate) => true;
}

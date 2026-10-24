import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'file_paths.dart';
import 'session_controller.dart';
import 'translations.dart';

class TrafficDialog extends StatefulWidget {
  const TrafficDialog({super.key, required this.session});
  final SessionController session;
  @override
  State<TrafficDialog> createState() => _TrafficDialogState();
}

class _TrafficDialogState extends State<TrafficDialog> {
  String direction = 'all';
  String filter = '';
  List<Map<String, dynamic>>? frozen;
  String? error;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.session, appLanguage]),
    builder: (context, _) {
      final frames = (frozen ?? widget.session.traffic.toList())
          .where(
            (f) =>
                (direction == 'all' || f['direction'] == direction) &&
                '${f['hex']}'.toLowerCase().contains(filter.toLowerCase()),
          )
          .toList();
      String text() => frames
          .map((f) => '${f['time']}  ${f['direction']}  ${f['hex']}')
          .join('\n');
      final stats = widget.session.busStatistics;
      return AlertDialog(
        title: const LText('Bus traffic'),
        content: SizedBox(
          width: 900,
          height: 450,
          child: Column(
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final value in ['all', 'tx', 'rx'])
                    ChoiceChip(
                      label: LText(
                        value == 'all' ? 'All frames' : value.toUpperCase(),
                      ),
                      selected: direction == value,
                      onSelected: (_) => setState(() => direction = value),
                    ),
                  FilterChip(
                    label: LText(
                      frozen == null ? 'Pause display' : 'Resume display',
                    ),
                    selected: frozen != null,
                    onSelected: (value) => setState(
                      () => frozen = value
                          ? widget.session.traffic.toList()
                          : null,
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: text())),
                    child: const LText('Copy'),
                  ),
                  TextButton(
                    onPressed: () async {
                      final content = text();
                      final path = await chooseFilePath(
                        context,
                        save: true,
                        title: 'Export traffic log',
                        extension: 'txt',
                        suggestedName: 'traffic.txt',
                      );
                      if (path == null) return;
                      try {
                        await File(path).writeAsString(content, flush: true);
                      } catch (e) {
                        if (mounted) setState(() => error = userError(e));
                      }
                    },
                    child: const LText('Export log'),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      widget.session.traffic.clear();
                      frozen = null;
                    }),
                    child: const LText('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                decoration: InputDecoration(
                  labelText: tr('Filter hex bytes'),
                  prefixIcon: const Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => filter = value.trim()),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: LText(
                  'TX ${stats['tx_bytes'] ?? 0} B · RX ${stats['rx_bytes'] ?? 0} B · ${tr('Operations')} ${stats['operations'] ?? 0} · ${tr('Errors')} ${stats['errors'] ?? 0} · ${tr('Average')} ${((stats['average_ms'] as num?) ?? 0).toStringAsFixed(1)} ms',
                ),
              ),
              if (error != null) LText(error!),
              Expanded(
                child: SelectionArea(
                  child: ListView.builder(
                    itemCount: frames.length,
                    itemBuilder: (context, i) {
                      final frame = frames[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          '${frame['time']}  ${frame['direction'].toString().toUpperCase()}  ${frame['hex']}',
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 12,
                            color: frame['direction'] == 'tx'
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('Close'),
          ),
        ],
      );
    },
  );
}

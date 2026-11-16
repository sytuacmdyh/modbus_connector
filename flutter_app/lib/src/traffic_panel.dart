import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'file_paths.dart';
import 'session_controller.dart';
import 'translations.dart';

String _trafficTime(Object? value) {
  final raw = value?.toString() ?? '';
  final time = DateTime.tryParse(raw);
  if (time == null) return raw;
  return '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}.'
      '${time.millisecond.toString().padLeft(3, '0')}';
}

/// Display state belongs to the console, independently of capture and visibility.
class TrafficController extends ChangeNotifier {
  TrafficController(this.session);
  final SessionController session;
  String direction = 'all';
  final filter = TextEditingController();
  List<Map<String, dynamic>>? frozen;
  bool get paused => frozen != null;

  List<Map<String, dynamic>> get frames => (frozen ?? session.traffic.toList())
      .where(
        (frame) =>
            (direction == 'all' || frame['direction'] == direction) &&
            '${frame['hex']}'.toLowerCase().contains(
              filter.text.trim().toLowerCase(),
            ),
      )
      .toList();

  String get text => frames
      .map((f) => '${f['time']}  ${f['direction']}  ${f['hex']}')
      .join('\n');

  void setDirection(String value) {
    direction = value;
    notifyListeners();
  }

  void filterChanged(String _) => notifyListeners();
  void togglePause() {
    frozen = paused ? null : session.traffic.toList();
    notifyListeners();
  }

  void clear() {
    frozen = null;
    session.clearTraffic();
    notifyListeners();
  }

  @override
  void dispose() {
    filter.dispose();
    super.dispose();
  }
}

class TrafficToolbar extends StatelessWidget {
  const TrafficToolbar({super.key, required this.controller});
  final TrafficController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, appLanguage]),
    builder: (context, _) {
      Widget action(String label, IconData icon, VoidCallback onPressed) =>
          IconButton(
            tooltip: tr(label),
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            padding: EdgeInsets.zero,
            iconSize: 18,
            onPressed: onPressed,
            icon: Icon(icon),
          );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 92,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const ValueKey('traffic-direction'),
                isDense: true,
                isExpanded: true,
                value: controller.direction,
                style: Theme.of(context).textTheme.bodySmall,
                items: [
                  for (final value in ['all', 'tx', 'rx'])
                    DropdownMenuItem(
                      value: value,
                      child: LText(
                        value == 'all' ? 'All frames' : value.toUpperCase(),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) controller.setDirection(value);
                },
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 136,
            height: 30,
            child: Theme(
              data: Theme.of(context)
                  .copyWith(visualDensity: VisualDensity.standard),
              child: TextField(
                key: const ValueKey('traffic-hex-filter'),
                controller: controller.filter,
                textAlignVertical: TextAlignVertical.center,
                style: Theme.of(context).textTheme.bodySmall,
                decoration: InputDecoration(
                  // Dense decoration can paint a short border at the top of
                  // the field's hit-test box. Fill the toolbar's fixed height.
                  isDense: false,
                  hintText: tr('Filter hex bytes'),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 0,
                  ),
                  border: const OutlineInputBorder(),
                ),
                onChanged: controller.filterChanged,
              ),
            ),
          ),
          action(
            controller.paused ? 'Resume display' : 'Pause display',
            controller.paused ? Icons.play_arrow : Icons.pause,
            controller.togglePause,
          ),
          action(
            'Copy',
            Icons.copy_outlined,
            () => Clipboard.setData(ClipboardData(text: controller.text)),
          ),
          action('Export traffic log', Icons.download_outlined, () async {
            final content = controller.text;
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
            } catch (error) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: LText(userError(error))));
              }
            }
          }),
          action('Clear', Icons.delete_sweep_outlined, controller.clear),
        ],
      );
    },
  );
}

class TrafficPanel extends StatefulWidget {
  const TrafficPanel({super.key, required this.controller, this.active = true});
  final TrafficController controller;
  final bool active;
  @override
  State<TrafficPanel> createState() => _TrafficPanelState();
}

class _TrafficPanelState extends State<TrafficPanel> {
  final _scroll = ScrollController();
  bool _followLatest = true;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.controller,
      if (widget.active) widget.controller.session.trafficUpdates,
      appLanguage,
    ]),
    builder: (context, _) {
      final controller = widget.controller;
      final frames = controller.frames;
      final stats = controller.session.busStatistics;
      if (widget.active && _followLatest && !controller.paused) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _scroll.hasClients &&
              widget.active &&
              _followLatest &&
              !controller.paused) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectionArea(
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification is UserScrollNotification ||
                          (notification is ScrollUpdateNotification &&
                              notification.dragDetails != null)) {
                        _followLatest = notification.metrics.extentAfter < 24;
                      }
                      return false;
                    },
                    child: ListView.builder(
                      key: const ValueKey('traffic-list'),
                      controller: _scroll,
                      primary: false,
                      itemCount: frames.length,
                      itemBuilder: (context, i) {
                        final frame = frames[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                            '${_trafficTime(frame['time'])}  ${frame['direction'].toString().toUpperCase()}  ${frame['hex']}',
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
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: LText(
                    'TX ${stats['tx_bytes'] ?? 0} B · RX ${stats['rx_bytes'] ?? 0} B · ${tr('Operations')} ${stats['operations'] ?? 0} · ${tr('Errors')} ${stats['errors'] ?? 0} · ${tr('Average')} ${((stats['average_ms'] as num?) ?? 0).toStringAsFixed(1)} ms',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

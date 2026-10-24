import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'bridge_client.dart';
import 'graph_dialog.dart';
import 'session_controller.dart';
import 'translations.dart';

class _ViewerTransport extends BridgeTransport {
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) =>
      Future.error(const BridgeException('Graph viewer has no bus connection'));
  @override
  Future<void> close() async {}
}

class GraphWindow extends StatefulWidget {
  const GraphWindow({super.key});
  @override
  State<GraphWindow> createState() => _GraphWindowState();
}

class _GraphWindowState extends State<GraphWindow> {
  final session = SessionController(_ViewerTransport());
  StreamSubscription<String>? input;
  bool initialized = false;
  @override
  void initState() {
    super.initState();
    input = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final data = jsonDecode(line) as Map<String, dynamic>;
          appLanguage.value = data['language'] as String;
          appTheme.value = ThemeMode.values.firstWhere(
            (m) => m.name == data['theme'],
            orElse: () => ThemeMode.system,
          );
          if (!initialized) {
            if (data['settings'] is Map) {
              session.draft['graph:master'] = data['settings'];
            }
            initialized = true;
          }
          session.histories.clear();
          session.historyLabels.clear();
          for (final e in (data['labels'] as Map).entries) {
            final key = e.key as String;
            session.historyLabels[key] = e.value as String;
            session.histories[key] = Queue<Sample>.from([
              for (final p in (data['series'] as Map)[key] as List? ?? [])
                Sample(
                  DateTime.fromMicrosecondsSinceEpoch((p as List)[0] as int),
                  (p[1] as num).toDouble(),
                ),
            ]);
          }
          if (mounted) setState(() {});
        }, onDone: () => exit(0));
  }

  void send(Map<String, dynamic> data) => stdout.writeln(jsonEncode(data));
  @override
  void dispose() {
    unawaited(input?.cancel());
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: initialized
        ? GraphDialog(session: session, detached: true, onViewerCommand: send)
        : const Center(child: CircularProgressIndicator()),
  );
}

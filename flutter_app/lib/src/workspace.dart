import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'bridge_client.dart';
import 'session_controller.dart';
import 'workbench.dart';

class WorkspaceController extends ChangeNotifier {
  WorkspaceController({BridgeTransport Function()? bridgeFactory})
    : bridgeFactory = bridgeFactory ?? ProcessBridge.new {
    add();
  }
  final BridgeTransport Function() bridgeFactory;
  final List<SessionController> sessions = [];
  int selected = 0;
  bool closing = false;
  void add() {
    if (closing) return;
    sessions.add(SessionController(bridgeFactory()));
    selected = sessions.length - 1;
    notifyListeners();
  }

  void select(int index) {
    selected = index;
    notifyListeners();
  }

  Future<void> remove(SessionController session) async {
    if (closing || !sessions.contains(session)) return;
    await session.shutdown();
    if (closing || !sessions.contains(session)) return;
    final index = sessions.indexOf(session);
    sessions.removeAt(index);
    session.dispose();
    if (selected > index) selected--;
    if (selected >= sessions.length) selected = sessions.length - 1;
    if (sessions.isEmpty) add();
    notifyListeners();
  }

  Future<void> shutdown() async {
    closing = true;
    await Future.wait(sessions.map((s) => s.shutdown()));
  }

  @override
  void dispose() {
    unawaited(shutdown());
    for (final session in sessions) {
      session.dispose();
    }
    super.dispose();
  }
}

class SessionWorkspace extends StatefulWidget {
  const SessionWorkspace({
    super.key,
    required this.themeMode,
    required this.onThemeChanged,
    this.controller,
  });
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final WorkspaceController? controller;
  @override
  State<SessionWorkspace> createState() => _SessionWorkspaceState();
}

class _SessionWorkspaceState extends State<SessionWorkspace> {
  late final workspace = widget.controller ?? WorkspaceController();
  late final AppLifecycleListener lifecycle;
  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await workspace.shutdown();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    lifecycle.dispose();
    if (widget.controller == null) workspace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: workspace,
    builder: (context, _) => Scaffold(
      body: Column(
        children: [
          SizedBox(
            height: 42,
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < workspace.sessions.length; i++)
                          ListenableBuilder(
                            listenable: workspace.sessions[i],
                            builder: (context, _) => Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: InputChip(
                                selected: workspace.selected == i,
                                avatar: Icon(
                                  workspace.sessions[i].connected
                                      ? Icons.link
                                      : Icons.tab,
                                  size: 16,
                                ),
                                label: Text('Session ${i + 1}'),
                                onPressed: () => workspace.select(i),
                                onDeleted: () => unawaited(
                                  workspace.remove(workspace.sessions[i]),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'New session',
                  onPressed: workspace.add,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: workspace.selected,
              children: [
                for (final session in workspace.sessions)
                  Workbench(
                    key: ObjectKey(session),
                    controller: session,
                    manageLifecycle: false,
                    themeMode: widget.themeMode,
                    onThemeChanged: widget.onThemeChanged,
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

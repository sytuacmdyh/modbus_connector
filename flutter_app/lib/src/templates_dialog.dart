import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'tool_widgets.dart';

class TemplatesDialog extends StatefulWidget {
  const TemplatesDialog({
    super.key,
    required this.session,
    required this.onOpen,
  });
  final SessionController session;
  final void Function(Map<String, dynamic>, String?) onOpen;
  @override
  State<TemplatesDialog> createState() => _TemplatesDialogState();
}

class _TemplatesDialogState extends State<TemplatesDialog> {
  List<Map<String, dynamic>> public = [];
  List<Map<String, dynamic>> custom = [];
  List<Map<String, dynamic>> versions = [];
  Map<String, dynamic>? selected;
  String? version;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<Map<String, dynamic>?> call(
    String command, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (mounted) setState(() => busy = true);
    final reply = await widget.session.command({'command': command, ...args});
    if (mounted) {
      setState(() {
        busy = false;
        error = reply == null ? widget.session.error : null;
      });
    }
    return reply;
  }

  Future<void> refresh() async {
    final result = await call('template_list');
    if (result == null || !mounted) return;
    setState(() {
      public = (result['public'] as List).cast<Map<String, dynamic>>();
      custom = (result['custom'] as List).cast<Map<String, dynamic>>();
    });
  }

  Future<void> choose(Map<String, dynamic> entry) async {
    setState(() {
      selected = entry;
      version = null;
      versions = [];
    });
    if (entry['id'] != null) {
      final result = await call('template_versions', {
        'template_id': entry['id'],
      });
      if (result != null && mounted) {
        setState(
          () => versions = (result['versions'] as List)
              .cast<Map<String, dynamic>>(),
        );
      }
    }
  }

  Future<void> open() async {
    if (selected == null) return;
    final result = await call('template_load', {
      'resource': selected!['resource'],
      'template_id': selected!['id'],
      'version_id': version,
    });
    if (result == null || !mounted) return;
    widget.onOpen(
      result['state'] as Map<String, dynamic>,
      result['template_id'] as String?,
    );
    Navigator.pop(context);
  }

  Future<void> save(bool append) async {
    final name = append
        ? null
        : await textPrompt(context, 'New custom template name');
    if (!append && (name == null || name.trim().isEmpty)) return;
    final result = await call('template_save', {
      'name': name,
      'template_id': append ? widget.session.customTemplateId : null,
      'state': widget.session.state(),
    });
    if (result != null) {
      widget.session.customTemplateId = result['id'] as String;
    }
    await refresh();
  }

  Future<void> remove(bool history) async {
    if (selected?['id'] == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          history ? 'Delete selected version?' : 'Delete custom template?',
        ),
        content: Text('${selected!['name']}\n${history ? version ?? '' : ''}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    final result = await call(
      history ? 'template_delete_version' : 'template_delete',
      {'template_id': selected!['id'], 'version_id': version},
    );
    if (result != null) {
      if (history) {
        await choose(selected!);
      } else {
        selected = null;
        versions = [];
      }
    }
    await refresh();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Templates / custom history'),
    content: SizedBox(
      width: 780,
      height: 470,
      child: Column(
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 6,
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => save(false),
                child: const Text('Save as custom'),
              ),
              OutlinedButton(
                onPressed: busy || widget.session.customTemplateId == null
                    ? null
                    : () => save(true),
                child: const Text('Save new version'),
              ),
              TextButton(
                onPressed: busy ? null : refresh,
                child: const Text('Refresh catalog'),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null) Text(error!),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      const ListTile(title: Text('Public (read-only)')),
                      for (final e in public)
                        ListTile(
                          dense: true,
                          selected: selected == e,
                          title: Text('${e['manufacturer']} / ${e['name']}'),
                          onTap: busy ? null : () => choose(e),
                        ),
                      const ListTile(title: Text('Custom (Flutter storage)')),
                      for (final e in custom)
                        ListTile(
                          dense: true,
                          selected: selected?['id'] == e['id'],
                          title: Text(e['name'] as String),
                          onTap: busy ? null : () => choose(e),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(),
                Expanded(
                  child: Column(
                    children: [
                      Text(selected?['name'] as String? ?? 'Select a template'),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final v in versions)
                              ListTile(
                                title: Text(v['saved_at'] as String),
                                subtitle: Text(v['id'] as String),
                                selected: version == v['id'],
                                leading: Icon(
                                  version == v['id']
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_off,
                                ),
                                onTap: busy
                                    ? null
                                    : () => setState(
                                        () => version = v['id'] as String,
                                      ),
                              ),
                          ],
                        ),
                      ),
                      if (selected?['id'] != null)
                        Wrap(
                          children: [
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      final name = await textPrompt(
                                        context,
                                        'Rename custom template',
                                        value: selected!['name'] as String,
                                      );
                                      if (name != null) {
                                        await call('template_rename', {
                                          'template_id': selected!['id'],
                                          'name': name,
                                        });
                                        await refresh();
                                      }
                                    },
                              child: const Text('Rename'),
                            ),
                            TextButton(
                              onPressed: busy ? null : () => remove(false),
                              child: const Text('Delete template'),
                            ),
                            TextButton(
                              onPressed: busy || version == null
                                  ? null
                                  : () => remove(true),
                              child: const Text('Delete version'),
                            ),
                          ],
                        ),
                      const Text(
                        'Opening creates a disconnected tab. Saving appends a new snapshot; public templates stay read-only.',
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
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      FilledButton(
        onPressed: busy || selected == null ? null : open,
        child: Text(
          version == null ? 'Open latest in new tab' : 'Open selected version',
        ),
      ),
    ],
  );
}

import 'dart:async';

import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'tool_widgets.dart';
import 'translations.dart';

class CloudDialog extends StatefulWidget {
  const CloudDialog({super.key, required this.session});
  final SessionController session;
  @override
  State<CloudDialog> createState() => _CloudDialogState();
}

class _CloudDialogState extends State<CloudDialog> {
  final url = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final directory = TextEditingController(text: 'templates');
  final timeout = TextEditingController(text: '15');
  String mode = 'consumer';
  bool remember = false;
  bool busy = false;
  bool running = false;
  bool cancelling = false;
  String? selected;
  List<String> versions = [];
  String? message;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(
      const Duration(milliseconds: 350),
      (_) => unawaited(poll()),
    );
  }

  Map<String, dynamic> settings() => {
    'url': url.text.trim(),
    'username': username.text,
    'password': password.text,
    'templates_path': directory.text.trim(),
    'timeout': int.tryParse(timeout.text) ?? -1,
    'remember_password': remember,
    'mode': mode,
  };
  Future<void> load() async {
    setState(() => busy = true);
    final reply = await widget.session.command({
      'command': 'cloud_settings_load',
    });
    if (!mounted) return;
    setState(() {
      busy = false;
      if (reply != null) {
        final s = reply['settings'] as Map;
        url.text = s['url'] as String;
        username.text = s['username'] as String;
        password.text = s['password'] as String;
        directory.text = s['templates_path'] as String;
        timeout.text = '${s['timeout']}';
        remember = s['remember_password'] == true;
        mode = s['mode'] as String;
      }
    });
  }

  Future<void> poll() async {
    if (!running || busy || widget.session.busy) return;
    final status = await widget.session.command({'command': 'cloud_status'});
    if (!mounted || status == null) return;
    if (status['running'] == true) return;
    setState(() {
      running = false;
      cancelling = false;
      final result = status['result'] as Map?;
      message =
          status['error'] as String? ??
          (result == null ? 'Finished' : '${result['message'] ?? result}');
      if (result?['versions'] is List) {
        versions = (result!['versions'] as List).cast<String>();
        selected = null;
      }
    });
  }

  Future<bool> confirm(String title) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: LText(title),
      content: const LText(
        'Publish only the visible public template catalog; personal templates and sessions are excluded.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const LText('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const LText('Continue'),
        ),
      ],
    ),
  ).then((v) => v == true);
  Future<void> action(String action) async {
    if (action == 'publish' && !await confirm('Publish public templates?')) {
      return;
    }
    if (action == 'activate' &&
        !await confirm('Activate selected template version?')) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    final reply = await widget.session.command({
      'command': 'cloud_start',
      'action': action,
      'settings': settings(),
      if (action == 'activate' || action == 'download' && selected != null)
        'version': selected,
    });
    if (mounted) {
      setState(() {
        busy = false;
        running = reply != null;
        message = reply == null ? widget.session.error : 'Working…';
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    for (final c in [url, username, password, directory, timeout]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !running && !busy,
    child: AlertDialog(
      title: const LText('Cloud sync'),
      content: SizedBox(
        width: 760,
        height: 480,
        child: Column(
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                toolField(
                  'WebDAV URL',
                  url,
                  width: 440,
                  enabled: !running && !busy,
                ),
                toolChoice(
                  'Mode',
                  mode,
                  ['consumer', 'publisher'],
                  running || busy ? null : (v) => setState(() => mode = v),
                  width: 200,
                ),
                toolField(
                  'Username',
                  username,
                  width: 210,
                  enabled: !running && !busy,
                ),
                toolField(
                  'Password',
                  password,
                  width: 210,
                  secret: true,
                  enabled: !running && !busy,
                ),
                toolField(
                  'Templates path',
                  directory,
                  width: 170,
                  enabled: !running && !busy,
                ),
                toolField(
                  'Timeout, s',
                  timeout,
                  width: 100,
                  enabled: !running && !busy,
                ),
              ],
            ),
            CheckboxListTile(
              dense: true,
              title: const LText('Save password as plaintext on this computer'),
              value: remember,
              onChanged: running || busy
                  ? null
                  : (v) => setState(() => remember = v!),
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: running || busy
                      ? null
                      : () async {
                          final result = await widget.session.command({
                            'command': 'cloud_settings_save',
                            'settings': settings(),
                          });
                          if (mounted) {
                            setState(
                              () => message = result == null
                                  ? widget.session.error
                                  : 'Connection settings saved',
                            );
                          }
                        },
                  child: const LText('Save connection settings'),
                ),
                OutlinedButton(
                  onPressed: running || busy ? null : () => action('test'),
                  child: const LText('Test connection'),
                ),
                OutlinedButton(
                  onPressed: running || busy ? null : () => action('download'),
                  child: LText(
                    selected == null
                        ? 'Download current templates'
                        : 'Download selected version',
                  ),
                ),
                OutlinedButton(
                  onPressed: running || busy ? null : () => action('versions'),
                  child: const LText('Template history'),
                ),
                if (mode == 'publisher') ...[
                  OutlinedButton(
                    onPressed: running || busy ? null : () => action('publish'),
                    child: const LText('Publish templates'),
                  ),
                  OutlinedButton(
                    onPressed: running || busy || selected == null
                        ? null
                        : () => action('activate'),
                    child: const LText('Activate version'),
                  ),
                ],
              ],
            ),
            if (running || busy) const LinearProgressIndicator(),
            if (message != null)
              Padding(padding: const EdgeInsets.all(8), child: LText(message!)),
            Expanded(
              child: ListView(
                children: [
                  for (final version in versions)
                    ListTile(
                      dense: true,
                      title: Text(version),
                      selected: selected == version,
                      leading: Icon(
                        selected == version
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      onTap: running || busy
                          ? null
                          : () => setState(() => selected = version),
                    ),
                ],
              ),
            ),
            if (selected != null)
              TextButton(
                onPressed: running || busy
                    ? null
                    : () => setState(() => selected = null),
                child: const LText('Use current catalog'),
              ),
            const LText(
              'Only public templates are synced. Downloads replace the Flutter cache; sessions and custom templates stay separate.',
            ),
          ],
        ),
      ),
      actions: [
        if (running)
          FilledButton(
            onPressed: cancelling
                ? null
                : () async {
                    setState(() => cancelling = true);
                    await widget.session.command({'command': 'cloud_cancel'});
                  },
            child: LText(cancelling ? 'Cancelling…' : 'Cancel transfer'),
          ),
        TextButton(
          onPressed: running || busy ? null : () => Navigator.pop(context),
          child: const LText('Close'),
        ),
      ],
    ),
  );
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.session});
  final SessionController session;
  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool busy = false;
  Map<String, dynamic>? result;
  String? error;
  Future<void> check() async {
    setState(() => busy = true);
    final reply = await widget.session.command({'command': 'update_check'});
    if (mounted) {
      setState(() {
        busy = false;
        result = reply;
        error = reply == null ? widget.session.error : null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const LText('Check for updates'),
      content: SizedBox(
        width: 680,
        height: 390,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (busy) const LinearProgressIndicator(),
            if (error != null) LText(error!),
            if (result != null) ...[
              LText(
                'Current ${result!['current']} · ${result!['release'] == null
                    ? 'No public stable release'
                    : result!['newer'] == true
                    ? 'New version available'
                    : 'Up to date'}',
              ),
              if (result!['release'] != null)
                LText('Latest: ${result!['release']['tag']}'),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    result!['release']?['notes'] as String? ??
                        tr('No release notes.'),
                  ),
                ),
              ),
              LText(result!['install_reason'] as String),
              const SizedBox(height: 8),
              SelectableText(result!['url'] as String),
            ] else
              const Expanded(
                child: Center(
                  child: LText(
                    'Manual check of public stable GitHub releases.',
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const LText('Close'),
        ),
        OutlinedButton(
          onPressed: busy
              ? null
              : () => widget.session.command({'command': 'update_open_page'}),
          child: const LText('Open releases page'),
        ),
        const OutlinedButton(onPressed: null, child: LText('Install update')),
        FilledButton(
          onPressed: busy ? null : check,
          child: const LText('Check now'),
        ),
      ],
    ),
  );
}

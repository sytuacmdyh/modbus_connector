import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'translations.dart';

/// Reuses the session's serialized, cancellable bridge request path.
class SerialPortPicker extends StatefulWidget {
  const SerialPortPicker({
    super.key,
    required this.session,
    required this.onSelected,
    this.enabled = true,
  });
  final SessionController session;
  final ValueChanged<String> onSelected;
  final bool enabled;
  @override
  State<SerialPortPicker> createState() => _SerialPortPickerState();
}

class _SerialPortPickerState extends State<SerialPortPicker> {
  bool refreshing = false;
  Future<void> discover() async {
    setState(() => refreshing = true);
    final ports = await widget.session.ports();
    if (!mounted) return;
    setState(() => refreshing = false);
    if (!widget.enabled || widget.session.error != null) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const LText('Serial ports'),
        children: [
          if (ports.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: LText(
                'No serial ports found. You can type a port manually.',
              ),
            ),
          for (final p in ports)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p['port'] as String),
              child: Text('${p['port']} · ${p['description']}'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: const LText('Cancel'),
          ),
        ],
      ),
    );
    if (mounted && widget.enabled && selected != null) {
      widget.onSelected(selected);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tr('Find serial ports'),
    onPressed: widget.enabled && !refreshing && !widget.session.busy
        ? discover
        : null,
    icon: refreshing
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.refresh),
  );
}

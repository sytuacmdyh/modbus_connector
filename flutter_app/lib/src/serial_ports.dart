import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'translations.dart';

/// Reuses the session's serialized, cancellable bridge request path.
class SerialPortPicker extends StatefulWidget {
  const SerialPortPicker({
    super.key,
    required this.session,
    required this.controller,
    this.enabled = true,
    this.width = 180,
    this.validator,
    this.onSubmit,
    this.onRefreshingChanged,
  });
  final SessionController session;
  final TextEditingController controller;
  final bool enabled;
  final double width;
  final FormFieldValidator<String>? validator;
  final VoidCallback? onSubmit;
  final ValueChanged<bool>? onRefreshingChanged;
  @override
  State<SerialPortPicker> createState() => _SerialPortPickerState();
}

class _SerialPortPickerState extends State<SerialPortPicker> {
  final menu = MenuController();
  final focus = FocusNode();
  bool refreshing = false;
  List<Map<String, dynamic>> ports = [];

  Future<void> discover() async {
    if (refreshing || widget.session.busy || !widget.enabled) return;
    menu.close();
    setState(() => refreshing = true);
    widget.onRefreshingChanged?.call(true);
    final found = await widget.session.ports();
    if (!mounted) return;
    setState(() {
      refreshing = false;
      ports = found;
    });
    widget.onRefreshingChanged?.call(false);
    // Parents may lock the field while discovery owns the session transaction.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled && widget.session.error == null) {
        menu.open();
      }
    });
  }

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !refreshing && !widget.session.busy;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MenuAnchor(
          controller: menu,
          childFocusNode: focus,
          style: const MenuStyle(
            maximumSize: WidgetStatePropertyAll(Size(420, 320)),
          ),
          menuChildren: [
            if (ports.isEmpty)
              const MenuItemButton(
                child: SizedBox(
                  width: 280,
                  child: LText(
                    'No serial ports found. You can type a port manually.',
                  ),
                ),
              ),
            for (final p in ports)
              MenuItemButton(
                onPressed: enabled
                    ? () {
                        widget.controller.text = p['port'] as String;
                        focus.requestFocus();
                      }
                    : null,
                child: Text('${p['port']} · ${p['description']}'),
              ),
          ],
          builder: (context, controller, child) => SizedBox(
            width: widget.width,
            child: TextFormField(
              controller: widget.controller,
              focusNode: focus,
              enabled: enabled,
              validator: widget.validator,
              onFieldSubmitted: (_) => widget.onSubmit?.call(),
              decoration: InputDecoration(
                labelText: tr('Serial port'),
                suffixIcon: IconButton(
                  tooltip: tr('Serial ports'),
                  onPressed: enabled
                      ? () {
                          if (controller.isOpen) {
                            controller.close();
                          } else {
                            discover();
                          }
                        }
                      : null,
                  icon: const Icon(Icons.arrow_drop_down),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: tr('Find serial ports'),
          onPressed: enabled ? discover : null,
          icon: refreshing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
      ],
    );
  }
}

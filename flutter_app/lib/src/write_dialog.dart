import 'package:flutter/material.dart';

class WriteDialog extends StatefulWidget {
  const WriteDialog({
    super.key,
    required this.address,
    required this.isBit,
    required this.current,
  });
  final int address;
  final bool isBit;
  final Object current;

  @override
  State<WriteDialog> createState() => _WriteDialogState();
}

class _WriteDialogState extends State<WriteDialog> {
  final _form = GlobalKey<FormState>();
  late final _input = TextEditingController(
    text: widget.current is bool
        ? (widget.current == true ? '1' : '0')
        : '${widget.current}',
  );

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, int.parse(_input.text));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      'Write ${widget.isBit ? 'coil' : 'register'} @${widget.address}',
    ),
    content: SizedBox(
      width: 320,
      child: Form(
        key: _form,
        child: TextFormField(
          autofocus: true,
          controller: _input,
          onFieldSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: widget.isBit
                ? 'Value · 0 or 1'
                : 'Unsigned value · 0–65535',
            helperText: 'Decimal or 0x hexadecimal',
          ),
          validator: (text) {
            final value = int.tryParse(text ?? '');
            final max = widget.isBit ? 1 : 65535;
            return value != null && value >= 0 && value <= max
                ? null
                : '0–$max';
          },
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Write')),
    ],
  );
}

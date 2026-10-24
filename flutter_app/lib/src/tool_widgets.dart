import 'translations.dart';

import 'package:flutter/material.dart';

Widget toolField(
  String label,
  TextEditingController controller, {
  double width = 140,
  bool enabled = true,
  int lines = 1,
  bool secret = false,
}) => SizedBox(
  width: width,
  child: TextField(
    controller: controller,
    enabled: enabled,
    maxLines: lines,
    obscureText: secret,
    decoration: InputDecoration(labelText: tr(label)),
  ),
);
Widget toolChoice(
  String label,
  String value,
  Iterable<String> choices,
  ValueChanged<String>? changed, {
  double width = 180,
}) => SizedBox(
  width: width,
  child: DropdownButtonFormField<String>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: tr(label)),
    items: choices
        .map(
          (v) => DropdownMenuItem(
            value: v,
            child: LText(v, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: changed == null
        ? null
        : (v) {
            if (v != null) changed(v);
          },
  ),
);
Future<String?> textPrompt(
  BuildContext context,
  String title, {
  String value = '',
  int lines = 1,
}) async {
  final input = TextEditingController(text: value);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: LText(title),
      content: SizedBox(
        width: 540,
        child: TextField(
          controller: input,
          autofocus: true,
          minLines: lines,
          maxLines: lines,
          onSubmitted: lines == 1 ? (v) => Navigator.pop(context, v) : null,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const LText('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, input.text),
          child: const LText('Apply'),
        ),
      ],
    ),
  );
  // Let the dialog's exit animation release its editable text before disposal.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  input.dispose();
  return result;
}

Future<void> showText(BuildContext context, String title, String content) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: LText(title),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(child: SelectableText(content)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('Close'),
          ),
        ],
      ),
    );

Future<String?> expressionPrompt(
  BuildContext context, {
  required String value,
  required Iterable<String> names,
}) async {
  final input = TextEditingController(text: value);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const LText('Expression rule'),
      content: SizedBox(
        width: 540,
        height: 290,
        child: Column(
          children: [
            TextField(
              controller: input,
              autofocus: true,
              minLines: 2,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: tr('Blank rule means manual'),
              ),
            ),
            const SizedBox(height: 8),
            const LText('Insert a reference or function at the cursor'),
            Expanded(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final token in [
                      't',
                      'prev',
                      'sin()',
                      'cos()',
                      'abs()',
                      'min(,)',
                      'max(,)',
                      'rand()',
                      'randint(0, 100)',
                      ...names.map((n) => '[$n]'),
                    ])
                      ActionChip(
                        label: Text(token),
                        onPressed: () {
                          final selection = input.selection;
                          final start = selection.isValid
                              ? selection.start
                              : input.text.length;
                          final end = selection.isValid
                              ? selection.end
                              : input.text.length;
                          input.value = TextEditingValue(
                            text: input.text.replaceRange(start, end, token),
                            selection: TextSelection.collapsed(
                              offset: start + token.length,
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const LText('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, input.text),
          child: const LText('Apply'),
        ),
      ],
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 250));
  input.dispose();
  return result;
}

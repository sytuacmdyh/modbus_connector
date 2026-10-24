import 'package:flutter/material.dart';

import 'logging_dialog.dart';
import 'session_controller.dart';
import 'tool_widgets.dart';
import 'translations.dart';

class ExpressionsDialog extends StatefulWidget {
  const ExpressionsDialog({super.key, required this.session});
  final SessionController session;
  @override
  State<ExpressionsDialog> createState() => _ExpressionsDialogState();
}

class _ExpressionsDialogState extends State<ExpressionsDialog> {
  Future<void> edit([int? index]) async {
    final previous = index == null ? null : widget.session.expressions[index];
    final name = await textPrompt(
      context,
      'Expression name',
      value: previous?['name'] as String? ?? 'Expression',
    );
    if (name == null || !mounted) return;
    final text = await textPrompt(
      context,
      'Expression: [register name], arithmetic, sin(), sqrt(), clamp()',
      value: previous?['text'] as String? ?? '',
    );
    if (text == null || !mounted) return;
    setState(() {
      final row = {...?previous, 'name': name, 'text': text};
      if (index == null) {
        widget.session.expressions.add(row);
      } else {
        widget.session.expressions[index] = row;
      }
    });
    await widget.session.evaluateExpressions();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) => AlertDialog(
      title: const LText('Expressions'),
      content: SizedBox(
        width: 700,
        height: 400,
        child: Column(
          children: [
            Wrap(
              spacing: 10,
              children: [
                OutlinedButton(
                  onPressed: widget.session.busy ? null : edit,
                  child: const LText('Add expression'),
                ),
                OutlinedButton(
                  onPressed: widget.session.busy
                      ? null
                      : widget.session.evaluateExpressions,
                  child: const LText('Evaluate'),
                ),
              ],
            ),
            const LText(
              'References use the latest scaled primary values of named register-map rows. Map polling updates expressions and their graph/alarm values.',
            ),
            Expanded(
              child: ListView(
                children: [
                  for (var i = 0; i < widget.session.expressions.length; i++)
                    Builder(
                      builder: (context) {
                        final row = widget.session.expressions[i];
                        final result =
                            i < widget.session.expressionResults.length
                            ? widget.session.expressionResults[i]
                            : null;
                        return ListTile(
                          title: Text('${row['name']} = ${row['text']}'),
                          subtitle: LText(
                            '${result?['display'] ?? '—'} ${tr(result?['error'] as String? ?? '')}',
                            style: TextStyle(
                              color: result?['alarm'] == null
                                  ? null
                                  : Colors.red,
                            ),
                          ),
                          onTap: widget.session.busy ? null : () => edit(i),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: tr('Alarm rules'),
                                onPressed: widget.session.busy
                                    ? null
                                    : () async {
                                        final rules =
                                            await showDialog<
                                              List<Map<String, dynamic>>
                                            >(
                                              context: context,
                                              builder: (_) => AlarmRulesDialog(
                                                rules:
                                                    (row['alarms'] as List? ??
                                                            [])
                                                        .cast<
                                                          Map<String, dynamic>
                                                        >(),
                                              ),
                                            );
                                        if (rules != null && mounted) {
                                          setState(() => row['alarms'] = rules);
                                          await widget.session
                                              .evaluateExpressions();
                                        }
                                      },
                                icon: const Icon(Icons.notifications_outlined),
                              ),
                              IconButton(
                                tooltip: tr('Remove expression'),
                                onPressed: widget.session.busy
                                    ? null
                                    : () => setState(() {
                                        widget.session.expressions.removeAt(i);
                                        widget.session.expressionResults = [];
                                      }),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        );
                      },
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
          child: const LText('Close'),
        ),
      ],
    ),
  );
}

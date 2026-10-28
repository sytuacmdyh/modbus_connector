import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'translations.dart';

const expressionFunctions = [
  'abs',
  'sqrt',
  'exp',
  'log',
  'log2',
  'log10',
  'sin',
  'cos',
  'tan',
  'asin',
  'acos',
  'atan',
  'floor',
  'ceil',
  'round',
  'min',
  'max',
  'pow',
  'clamp',
  'rand',
  'randint',
];

({int start, int end, List<String> words}) expressionCompletions(
  TextEditingValue value,
  Iterable<String> names,
) {
  final cursor = value.selection.isValid
      ? value.selection.extentOffset
      : value.text.length;
  final before = value.text.substring(0, cursor);
  final open = before.lastIndexOf('[');
  int start;
  int end = cursor;
  List<String> words;
  if (open > before.lastIndexOf(']')) {
    start = open + 1;
    words = names.toSet().map((n) => '$n]').toList();
    final close = value.text.indexOf(']', cursor);
    if (close >= 0 && !value.text.substring(cursor, close).contains('[')) {
      end = close + 1;
    }
  } else {
    final match = RegExp(r'[A-Za-z_][A-Za-z0-9_]*$').firstMatch(before);
    if (match == null) return (start: cursor, end: cursor, words: <String>[]);
    start = match.start;
    words = [...expressionFunctions.map((f) => '$f('), 'pi', 'e', 't', 'prev'];
    final suffix = RegExp(r'^[A-Za-z0-9_]*')
        .firstMatch(value.text.substring(cursor))!;
    end += suffix.end;
    if (end < value.text.length && value.text[end] == '(') end++;
  }
  final prefix = before.substring(start).toLowerCase();
  final matches =
      words.where((w) => w.toLowerCase().startsWith(prefix)).toList()..sort();
  if (matches.length == 1 && matches.single.toLowerCase() == prefix) {
    matches.clear();
  }
  return (start: start, end: end, words: matches);
}

class ExpressionRuleEditor extends StatefulWidget {
  const ExpressionRuleEditor({
    super.key,
    required this.controller,
    required this.names,
  });
  final TextEditingController controller;
  final Iterable<String> names;
  @override
  State<ExpressionRuleEditor> createState() => _ExpressionRuleEditorState();
}

class _ExpressionRuleEditorState extends State<ExpressionRuleEditor> {
  late final FocusNode focus = FocusNode(onKeyEvent: keyEvent);
  int highlighted = 0;
  bool dismissed = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
  }

  void changed() => setState(() {
    highlighted = 0;
    dismissed = false;
  });
  @override
  void dispose() {
    widget.controller.removeListener(changed);
    focus.dispose();
    super.dispose();
  }

  void insert(String word) {
    final value = widget.controller.value;
    final completion = expressionCompletions(value, widget.names);
    widget.controller.value = TextEditingValue(
      text: value.text.replaceRange(completion.start, completion.end, word),
      selection: TextSelection.collapsed(
        offset: completion.start + word.length,
      ),
    );
    setState(() => dismissed = true);
    focus.requestFocus();
  }

  KeyEventResult keyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final words = expressionCompletions(
      widget.controller.value,
      widget.names,
    ).words;
    if (dismissed || words.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => dismissed = true);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(
        () => highlighted =
            (highlighted +
                (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1)) %
            words.length,
      );
    } else if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      insert(words[highlighted.clamp(0, words.length - 1)]);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final words = expressionCompletions(
      widget.controller.value,
      widget.names,
    ).words;
    return Column(
      children: [
        TextField(
          controller: widget.controller,
          focusNode: focus,
          autofocus: true,
          decoration: InputDecoration(labelText: tr('Blank rule means manual')),
        ),
        if (!dismissed && words.isNotEmpty)
          SizedBox(
            height: 110,
            child: ListView.builder(
              itemCount: words.length,
              itemExtent: 36,
              itemBuilder: (context, i) => ListTile(
                dense: true,
                selected: i == highlighted,
                title: Text(words[i]),
                onTap: () => insert(words[i]),
              ),
            ),
          ),
      ],
    );
  }
}

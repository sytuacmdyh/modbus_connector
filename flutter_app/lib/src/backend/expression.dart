import 'dart:math' as math;

typedef NumericExpression = double Function(Map<String, num> values);

// A bounded arithmetic parser; no eval, reflection, property access or code execution.
class Expression {
  Expression(String text, {this.simulator = false}) {
    if (text.length > 8192) throw const FormatException('Expression too long');
    final pattern = RegExp(
      r'\s*(\[[^\[\]]+\]|(?:0[xX][0-9a-fA-F]+)|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[a-zA-Z_]\w*|\*\*|//|[+*/%(),-])',
    );
    var offset = 0;
    while (offset < text.trimRight().length) {
      final match = pattern.matchAsPrefix(text, offset);
      if (match == null) {
        throw const FormatException('Invalid expression syntax');
      }
      tokens.add(match[1]!);
      offset = match.end;
    }
    _root = _sum();
    if (position != tokens.length) {
      throw const FormatException('Invalid expression syntax');
    }
  }
  final bool simulator;
  final tokens = <String>[];
  int position = 0;
  int depth = 0;
  late NumericExpression _root;
  String get token => position < tokens.length ? tokens[position] : '';
  bool take(String t) {
    if (token != t) return false;
    position++;
    return true;
  }

  double evaluate(Map<String, num> values) {
    try {
      return _root(values);
    } on ArgumentError {
      return double.nan;
    }
  }

  NumericExpression _sum() {
    var left = _product();
    while (token == '+' || token == '-') {
      final op = tokens[position++];
      final a = left;
      final b = _product();
      left = (v) => op == '+' ? a(v) + b(v) : a(v) - b(v);
    }
    return left;
  }

  NumericExpression _product() {
    var left = _unary();
    while (['*', '/', '//', '%'].contains(token)) {
      final op = tokens[position++];
      final a = left;
      final b = _unary();
      left = (v) {
        final x = a(v), y = b(v);
        if (y == 0 && op != '*') return double.nan;
        return switch (op) {
          '*' => x * y,
          '/' => x / y,
          '//' => (x / y).floorToDouble(),
          _ => x - (x / y).floorToDouble() * y,
        };
      };
    }
    return left;
  }

  NumericExpression _unary() {
    if (++depth > 128) {
      throw const FormatException('Expression nesting too deep');
    }
    try {
      if (take('+')) return _unary();
      if (take('-')) {
        final a = _unary();
        return (v) => -a(v);
      }
      final a = _atom();
      if (take('**')) {
        final b = _unary();
        return (v) => math.pow(a(v), b(v)).toDouble();
      }
      return a;
    } finally {
      depth--;
    }
  }

  NumericExpression _atom() {
    if (take('(')) {
      final a = _sum();
      if (!take(')')) throw const FormatException('Missing )');
      return a;
    }
    final t = token;
    if (t.isEmpty) {
      throw const FormatException('Expected a number or reference');
    }
    position++;
    if (t.startsWith('[')) {
      final name = t.substring(1, t.length - 1);
      if (name.trim().isEmpty) throw const FormatException('Empty reference');
      return (v) {
        if (!v.containsKey(name)) throw StateError('Missing reference: $name');
        return v[name]!.toDouble();
      };
    }
    final value = num.tryParse(t);
    if (value != null) return (_) => value.toDouble();
    if (t == 'pi') return (_) => math.pi;
    if (t == 'e') return (_) => math.e;
    if (simulator && (t == 't' || t == 'prev')) return (v) => v[t]!.toDouble();
    const functions = {
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
    };
    if (!functions.contains(t) &&
        !(simulator && {'rand', 'randint'}.contains(t))) {
      throw FormatException('Unknown function or name: $t');
    }
    if (!take('(')) throw const FormatException('Expected (');
    final args = <NumericExpression>[];
    if (!take(')')) {
      do {
        args.add(_sum());
      } while (take(','));
      if (!take(')')) throw const FormatException('Missing )');
    }
    final n = args.length;
    if ((t == 'rand' && n != 0) ||
        ({'pow', 'randint'}.contains(t) && n != 2) ||
        (t == 'clamp' && n != 3) ||
        ({'min', 'max'}.contains(t) && n < 1) ||
        (!{
              'rand',
              'pow',
              'randint',
              'clamp',
              'min',
              'max',
              'round',
              'log',
            }.contains(t) &&
            n != 1) ||
        ({'round', 'log'}.contains(t) && (n < 1 || n > 2))) {
      throw const FormatException('Invalid function arguments');
    }
    return (v) {
      final a = args.map((f) => f(v)).toList();
      final x = a.isEmpty ? 0.0 : a[0];
      return switch (t) {
        'abs' => x.abs(),
        'sqrt' => math.sqrt(x),
        'exp' => math.exp(x),
        'log' => math.log(x) / (n == 2 ? math.log(a[1]) : 1),
        'log2' => math.log(x) / math.ln2,
        'log10' => math.log(x) / math.ln10,
        'sin' => math.sin(x),
        'cos' => math.cos(x),
        'tan' => math.tan(x),
        'asin' => math.asin(x),
        'acos' => math.acos(x),
        'atan' => math.atan(x),
        'floor' => x.floorToDouble(),
        'ceil' => x.ceilToDouble(),
        'round' =>
          bankersRound(x * math.pow(10, n == 2 ? a[1].toInt() : 0)) /
              math.pow(10, n == 2 ? a[1].toInt() : 0),
        'min' => a.reduce(math.min),
        'max' => a.reduce(math.max),
        'pow' => math.pow(x, a[1]).toDouble(),
        'clamp' => x.clamp(a[1], a[2]).toDouble(),
        'rand' => math.Random().nextDouble(),
        'randint' =>
          (a[0].toInt() +
                  math.Random().nextInt(a[1].toInt() - a[0].toInt() + 1))
              .toDouble(),
        _ => double.nan,
      };
    };
  }
}

int bankersRound(num x) {
  final f = x.floor();
  final r = x - f;
  return r == 0.5 ? (f.isEven ? f : f + 1) : x.round();
}

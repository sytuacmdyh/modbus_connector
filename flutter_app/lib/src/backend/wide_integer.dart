/// Decimal arithmetic for exact 64-bit engineering text on VM and JavaScript.
/// Register words and wire messages remain 16-bit numbers; wide values are text.
class ExactDecimal {
  ExactDecimal(this.numerator, this.denominator);
  final BigInt numerator, denominator;
  factory ExactDecimal.parse(String text) {
    if (text.length > 2048) throw const FormatException('Number is too long');
    final match = RegExp(
      r'^([+-]?)(?:(\d+)(?:\.(\d*))?|\.(\d+))(?:[eE]([+-]?\d+))?$',
    ).firstMatch(text.trim());
    if (match == null) throw const FormatException('Invalid decimal number');
    final fraction = match[3] ?? match[4] ?? '';
    final exponent = int.tryParse(match[5] ?? '0');
    if (exponent == null || exponent.abs() > 400) {
      throw const FormatException('Decimal exponent is too large');
    }
    var numerator = BigInt.parse('${match[2] ?? '0'}$fraction');
    if (match[1] == '-') numerator = -numerator;
    final places = fraction.length - exponent;
    return places >= 0
        ? ExactDecimal(numerator, BigInt.from(10).pow(places))
        : ExactDecimal(numerator * BigInt.from(10).pow(-places), BigInt.one);
  }
  ExactDecimal operator +(ExactDecimal other) => ExactDecimal(
    numerator * other.denominator + other.numerator * denominator,
    denominator * other.denominator,
  );
  ExactDecimal operator -(ExactDecimal other) => ExactDecimal(
    numerator * other.denominator - other.numerator * denominator,
    denominator * other.denominator,
  );
  ExactDecimal operator *(ExactDecimal other) => ExactDecimal(
    numerator * other.numerator,
    denominator * other.denominator,
  );
  ExactDecimal operator /(ExactDecimal other) {
    if (other.numerator == BigInt.zero) {
      throw const FormatException('Cannot invert zero scale');
    }
    return other.numerator.isNegative
        ? ExactDecimal(
            -numerator * other.denominator,
            -other.numerator * denominator,
          )
        : ExactDecimal(
            numerator * other.denominator,
            other.numerator * denominator,
          );
  }

  BigInt roundEven() {
    final absolute = numerator.abs();
    var quotient = absolute ~/ denominator;
    final twiceRemainder = (absolute % denominator) * BigInt.two;
    if (twiceRemainder > denominator ||
        (twiceRemainder == denominator && quotient.isOdd)) {
      quotient += BigInt.one;
    }
    return numerator.isNegative ? -quotient : quotient;
  }

  String decimalText() {
    var rest = numerator.abs() % denominator;
    final whole = numerator.abs() ~/ denominator;
    final fraction = StringBuffer();
    // Display operands have decimal denominators, so division terminates.
    for (var i = 0; rest != BigInt.zero && i < 2048; i++) {
      rest *= BigInt.from(10);
      fraction.write(rest ~/ denominator);
      rest %= denominator;
    }
    if (rest != BigInt.zero) {
      throw const FormatException('Nonterminating decimal');
    }
    return '${numerator.isNegative ? '-' : ''}$whole${fraction.isEmpty ? '' : '.$fraction'}';
  }
}

BigInt wideFromBytes(List<int> bytes, {bool signed = false}) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  if (signed && bytes.first & 128 != 0) {
    value -= BigInt.one << (bytes.length * 8);
  }
  return value;
}

List<int> wideToBytes(BigInt value, {required bool signed}) {
  final low = signed ? -(BigInt.one << 63) : BigInt.zero;
  final high = (BigInt.one << (signed ? 63 : 64)) - BigInt.one;
  var x = value < low
      ? low
      : value > high
      ? high
      : value;
  if (x.isNegative) x += BigInt.one << 64;
  final bytes = List.filled(8, 0);
  for (var i = 7; i >= 0; i--) {
    bytes[i] = (x & BigInt.from(255)).toInt();
    x >>= 8;
  }
  return bytes;
}

import 'package:modbus_desktop/src/backend/registers.dart';
import 'package:test/test.dart';

void main() {
  test('firmware version uses BADC before decoding ASCII', () {
    final descriptor = row({
      'address': 17,
      'count': 4,
      'format': 'ascii',
      'order': 'BADC',
    });
    expect(
      render(descriptor, [0x3156, 0x302e, 0x302e, 0])['display'],
      'V1.0.0',
    );
    expect(encodeValues({'row': descriptor, 'text': 'V1.0.0'}), [
      0x3156,
      0x302e,
      0x302e,
      0,
    ]);
  });

  const cases = {
    'ABCD': [0x4865, 0x6c6c, 0x6f00],
    'BADC': [0x6548, 0x6c6c, 0x006f],
    'CDAB': [0x6f00, 0x6c6c, 0x4865],
    'DCBA': [0x006f, 0x6c6c, 0x6548],
  };
  for (final entry in cases.entries) {
    test('ASCII ${entry.key} decodes and encodes a padded string', () {
      final descriptor = row({
        'count': 3,
        'format': 'ascii',
        'order': entry.key,
      });
      expect(render(descriptor, entry.value)['display'], 'Hello');
      expect(encodeValues({'row': descriptor, 'text': 'Hello'}), entry.value);
      expect(encodeValues({'row': descriptor, 'text': ''}), [0, 0, 0]);
    });
    test('ASCII ${entry.key} truncates before reordering', () {
      final descriptor = row({
        'count': 1,
        'format': 'ascii',
        'order': entry.key,
      });
      final encoded = encodeValues({'row': descriptor, 'text': 'ABCDE'});
      expect(encoded, [
        entry.key == 'BADC' || entry.key == 'DCBA' ? 0x4241 : 0x4142,
      ]);
      expect(render(descriptor, encoded)['display'], 'AB');
    });
    test('ASCII1 ${entry.key} keeps one character per low byte', () {
      final descriptor = row({
        'count': 3,
        'format': 'ascii1',
        'order': entry.key,
      });
      expect(render(descriptor, [0xff41, 0xff42, 0])['display'], 'AB');
      expect(encodeValues({'row': descriptor, 'text': 'AB'}), [65, 66, 0]);
    });
  }

  test('ASCII stops at NUL and replaces nonprintable bytes after swapping', () {
    final descriptor = row({'count': 3, 'format': 'ascii', 'order': 'BADC'});
    expect(render(descriptor, [0x0141, 0x427f, 0x4300])['display'], 'A..B');
    expect(encodeValues({'row': descriptor, 'text': 'A中'}), [0x3f41, 0, 0]);
  });
}

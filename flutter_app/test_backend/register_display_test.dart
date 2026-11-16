import 'package:modbus_desktop/src/backend/registers.dart';
import 'package:test/test.dart';

void main() {
  // Xinghuan outdoor 721–723 use signed temperature words and a signed
  // sentinel name; 724/725 and 727/728 use unsigned words with 0.1 scaling.
  test('signed sentinel names match before engineering scaling', () {
    final temperature = row({
      'address': 721,
      'format': 's16',
      'scale': 0.1,
      'unit': '℃',
      'value_names': {'-32768': '异常（0x8000）'},
      'writable': false,
    });
    expect(render(temperature, [253])['display'], '25.3 ℃');
    expect(render(temperature, [65526])['display'], '-1 ℃');
    expect(render(temperature, [32768])['display'], '异常（0x8000） (-32768)');
  });

  test('legacy unsigned keys on signed words remain supported', () {
    final descriptor = row({
      'format': 's16',
      'value_names': {'65535': 'Legacy missing'},
    });
    expect(render(descriptor, [65535])['display'], 'Legacy missing (65535)');
  });

  test('unsigned sentinels and state names still match raw words', () {
    final pressure = row({
      'address': 724,
      'scale': 0.1,
      'unit': 'bar',
      'value_names': {'65535': '缺测（0xFFFF）'},
      'writable': false,
    });
    expect(render(pressure, [123])['display'], '12.3 bar');
    expect(render(pressure, [65535])['display'], '缺测（0xFFFF） (65535)');
  });
}

import 'package:modbus_desktop/src/backend/catalog.dart';
import 'package:test/test.dart';

void main() {
  test(
    'missing template column preferences use defaults; saved overrides survive',
    () {
      final state = <String, dynamic>{'connection': {}, 'registers': []};
      expect(flutterState(state)['draft']['map_table'], isEmpty);
      final legacy = flutterState({
        ...state,
        'registers_options': {
          'hidden_columns': [],
          'column_order': ['address', 'type'],
        },
      });
      expect(legacy['draft']['map_table'], {
        'hidden': [],
        'order': ['address', 'kind'],
      });
      final native = flutterState({
        ...state,
        'draft': {
          'map_table': {
            'hidden': ['raw'],
            'widths': {'name': 200},
          },
        },
      });
      expect(native['draft']['map_table'], {
        'hidden': ['raw'],
        'widths': {'name': 200},
      });
    },
  );
}

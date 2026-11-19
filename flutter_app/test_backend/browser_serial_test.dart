@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:modbus_desktop/src/backend/wire.dart';
import 'package:modbus_desktop/src/backend/wire_channel_web.dart' as web;
import 'package:test/test.dart';

@JS('navigator')
external JSObject get navigator;
@JS('Object.defineProperty')
external JSObject defineProperty(
  JSObject target,
  JSString key,
  JSObject descriptor,
);

JSObject object(Map<String, JSAny?> properties) {
  final result = JSObject();
  for (final entry in properties.entries) {
    result.setProperty(entry.key.toJS, entry.value);
  }
  return result;
}

void main() {
  test(
    'browser authorization, serial settings, RTU exchange and awaited cleanup',
    () async {
      final original = navigator.getProperty<JSAny?>('serial'.toJS);
      final responses = StreamController<JSObject>();
      final iterator = StreamIterator(responses.stream);
      JSObject? settings;
      final released = <String>[];
      var authorized = 0, closes = 0;
      final reader = object({
        'read': (() => (() async {
          if (await iterator.moveNext()) return iterator.current;
          return object({'done': true.toJS});
        })().toJS).toJS,
        'cancel': (() => (() async {
          unawaited(responses.close());
          return null;
        })().toJS).toJS,
        'releaseLock': (() {
          released.add('reader');
        }).toJS,
      });
      final writer = object({
        'write': ((JSUint8Array raw) {
          final bytes = raw.toDart;
          expect(bytes, rtuFrame(1, [3, 0, 0, 0, 1]));
          responses.add(
            object({
              'done': false.toJS,
              'value': Uint8List.fromList(rtuFrame(1, [3, 2, 0, 42])).toJS,
            }),
          );
          return Future<JSAny?>.value(null).toJS;
        }).toJS,
        'releaseLock': (() {
          released.add('writer');
        }).toJS,
      });
      final port = object({
        'open': ((JSObject options) {
          settings = options;
          return Future<JSAny?>.value(null).toJS;
        }).toJS,
        'readable': object({'getReader': (() => reader).toJS}),
        'writable': object({'getWriter': (() => writer).toJS}),
        'close': (() {
          expect(released, ['reader', 'writer']);
          closes++;
          return Future<JSAny?>.value(null).toJS;
        }).toJS,
      });
      defineProperty(
        navigator,
        'serial'.toJS,
        object({
          'configurable': true.toJS,
          'value': object({
            'requestPort': (() {
              authorized++;
              return Future.value(port).toJS;
            }).toJS,
          }),
        }),
      );
      final client = ModbusClient();
      try {
        expect(web.BrowserSerialPorts.supported, true);
        final selected = await web.BrowserSerialPorts.select();
        expect(authorized, 1);
        await client.connect({
          'transport': 'rtu',
          'port': selected!['port'],
          'baudrate': 19200,
          'parity': 'E',
          'stopbits': 2,
        });
        expect(
          settings!.getProperty<JSNumber>('baudRate'.toJS).toDartInt,
          19200,
        );
        expect(settings!.getProperty<JSString>('parity'.toJS).toDart, 'even');
        expect(settings!.getProperty<JSNumber>('stopBits'.toJS).toDartInt, 2);
        expect(await client.read(1, 'holding_registers', 0, 1), [42]);
        await client.close();
        await client.close();
        expect(closes, 1);
      } finally {
        await client.close();
        defineProperty(
          navigator,
          'serial'.toJS,
          object({'configurable': true.toJS, 'value': original}),
        );
      }
    },
  );
}

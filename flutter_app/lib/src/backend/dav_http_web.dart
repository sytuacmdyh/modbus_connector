import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'dav_http_contract.dart';

DavHttpClient openDavClient() => _BrowserDavClient();

class _BrowserDavClient implements DavHttpClient {
  final _abort = web.AbortController();

  @override
  Future<DavResponse> request(
    Uri uri, {
    required String method,
    required Map<String, String> headers,
    required Duration timeout,
    List<int>? body,
  }) => _request(uri, method, headers, body).timeout(
    timeout,
    onTimeout: () {
      close();
      throw TimeoutException('WebDAV request timed out', timeout);
    },
  );

  Future<DavResponse> _request(
    Uri uri,
    String method,
    Map<String, String> headers,
    List<int>? body,
  ) async {
    web.Response response;
    try {
      response = await web.window
          .fetch(
            uri.toString().toJS,
            web.RequestInit(
              method: method,
              headers: headers.jsify()! as JSObject,
              body: body == null ? null : Uint8List.fromList(body).toJS,
              mode: 'cors',
              credentials: 'omit',
              redirect: 'error',
              cache: 'no-store',
              signal: _abort.signal,
            ),
          )
          .toDart;
    } catch (_) {
      throw const DavException(
        'Cannot reach WebDAV. Check HTTPS, CORS, credentials and browser network permissions.',
      );
    }
    final declared = int.tryParse(response.headers.get('Content-Length') ?? '');
    if (declared != null && declared > cloudByteLimit) {
      close();
      throw const DavException('Cloud response exceeds the 16 MiB limit.');
    }
    final bytes = <int>[];
    final stream = response.body;
    if (stream != null) {
      final reader = stream.getReader() as web.ReadableStreamDefaultReader;
      try {
        while (true) {
          final chunk = await reader.read().toDart;
          if (chunk.done) break;
          final value = (chunk.value as JSUint8Array).toDart;
          if (bytes.length + value.length > cloudByteLimit) {
            close();
            throw const DavException(
              'Cloud response exceeds the 16 MiB limit.',
            );
          }
          bytes.addAll(value);
        }
      } finally {
        reader.releaseLock();
      }
    }
    return DavResponse(response.status, bytes);
  }

  @override
  void close() => _abort.abort();
}

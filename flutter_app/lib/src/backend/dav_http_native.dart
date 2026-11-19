import 'dart:async';
import 'dart:io';

import 'dav_http_contract.dart';

DavHttpClient openDavClient() => _NativeDavClient();

class _NativeDavClient implements DavHttpClient {
  final _client = HttpClient();

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
    final request = await _client.openUrl(method, uri);
    request.followRedirects = false;
    request.headers.set('User-Agent', 'ModbusConnector');
    headers.forEach(request.headers.set);
    if (body != null) request.add(body);
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > cloudByteLimit) {
        close();
        throw const DavException('Cloud response exceeds the 16 MiB limit.');
      }
      bytes.addAll(chunk);
    }
    return DavResponse(response.statusCode, bytes);
  }

  @override
  void close() => _client.close(force: true);
}

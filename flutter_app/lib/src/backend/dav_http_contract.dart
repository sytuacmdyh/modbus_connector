const cloudByteLimit = 16 * 1024 * 1024;

class DavException implements Exception {
  const DavException(this.message, [this.status]);
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class DavResponse {
  const DavResponse(this.status, this.bytes);
  final int status;
  final List<int> bytes;
}

abstract class DavHttpClient {
  Future<DavResponse> request(
    Uri uri, {
    required String method,
    required Map<String, String> headers,
    required Duration timeout,
    List<int>? body,
  });
  void close();
}

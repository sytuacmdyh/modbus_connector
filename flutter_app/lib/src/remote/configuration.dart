class ServiceConfiguration {
  ServiceConfiguration(String endpoint, this.token)
    : endpoint = validateEndpoint(endpoint);
  final String endpoint;
  final String token;
  static String validateEndpoint(String value) {
    final url = Uri.tryParse(value.trim());
    if (url == null ||
        !['ws', 'wss'].contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        url.path != '/ws') {
      throw const FormatException(
        'Use ws://host:port/ws or wss://host/ws without credentials or query parameters',
      );
    }
    return url.toString();
  }
}

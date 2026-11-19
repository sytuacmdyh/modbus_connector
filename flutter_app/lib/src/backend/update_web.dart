import 'update_contract.dart';
export 'update_contract.dart';

class InstallerAsset {
  InstallerAsset.fromJson(Map<String, dynamic> data) {
    throw UnsupportedError('Native installers are unavailable in the browser');
  }
}

class UpdateCancelled implements Exception {}

class UpdateInstaller {
  void cancel() {}
  Future<UpdateHandoff> prepare(
    InstallerAsset asset,
    void Function(double) onProgress,
  ) async => throw UnsupportedError(
    'Native installers are unavailable in the browser',
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const updateRepository = 'sytuacmdyh/modbus_connector';
const updateReleasesUrl = 'https://github.com/$updateRepository/releases';

Map<String, dynamic> releaseResult(
  Map<String, dynamic> release,
  String current, {
  String? executable,
}) {
  final tag = release['tag_name'];
  if (release['draft'] != false ||
      release['prerelease'] != false ||
      tag is! String ||
      !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag) ||
      (release['body'] != null && release['body'] is! String)) {
    throw const FormatException('Invalid GitHub release response.');
  }
  final parts = tag.substring(1).split('.').map(int.parse).toList();
  final local = current
      .replaceFirst(RegExp(r'^v'), '')
      .split(RegExp(r'[-+]'))[0]
      .split('.')
      .map(int.parse)
      .toList();
  if (local.length != 3) {
    throw const FormatException('Invalid application version.');
  }
  var newer = false;
  for (var i = 0; i < 3; i++) {
    if (parts[i] != local[i]) {
      newer = parts[i] > local[i];
      break;
    }
  }
  final asset = InstallerAsset.fromRelease(release);
  return {
    'current': current,
    'release': {
      'tag': tag,
      'notes': release['body'] ?? '',
      'installer': asset?.toJson(),
    },
    'url': '$updateReleasesUrl/tag/$tag',
    'newer': newer,
    'install_supported': newer && executable != null && asset != null,
    'install_reason': !newer
        ? 'You are up to date.'
        : executable == null
        ? 'Automatic installation requires a Windows installed copy. Use the releases page for manual installation.'
        : asset == null
        ? 'A verified Flutter installer is not available. Use the releases page for manual installation.'
        : 'The update is ready to download and install.',
  };
}

class InstallerAsset {
  const InstallerAsset(this.url, this.size, this.digest);
  final Uri url;
  final int size;
  final String digest;

  Map<String, dynamic> toJson() => {
    'url': url.toString(),
    'size': size,
    'sha256': digest,
  };

  static InstallerAsset? fromRelease(Map<String, dynamic> release) {
    final tag = release['tag_name'];
    if (tag is! String || !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) {
      return null;
    }
    final name =
        'modbus-connector-flutter-${tag.substring(1)}-windows-x64-setup.exe';
    final url =
        'https://github.com/$updateRepository/releases/download/$tag/$name';
    for (final a in release['assets'] is List ? release['assets'] : []) {
      if (a is! Map ||
          a['name'] != name ||
          a['state'] != 'uploaded' ||
          a['browser_download_url'] != url ||
          a['size'] is! int ||
          a['size'] <= 0 ||
          a['size'] > 1024 * 1024 * 1024 ||
          a['digest'] is! String ||
          !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(a['digest'])) {
        continue;
      }
      return InstallerAsset(
        Uri.parse(url),
        a['size'],
        a['digest'].substring(7).toLowerCase(),
      );
    }
    return null;
  }

  factory InstallerAsset.fromJson(Map<String, dynamic> value) {
    final asset = InstallerAsset(
      Uri.parse(value['url'] as String),
      value['size'] as int,
      value['sha256'] as String,
    );
    validateInstallerUrl(asset.url);
    if (asset.size <= 0 ||
        asset.size > 1024 * 1024 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(asset.digest)) {
      throw const FormatException('Invalid installer metadata.');
    }
    return asset;
  }
}

void validateInstallerUrl(Uri url) {
  if (url.scheme != 'https' ||
      url.userInfo.isNotEmpty ||
      url.port != 443 ||
      url.hasFragment ||
      !{
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      }.contains(url.host)) {
    throw const FormatException('Unsafe installer download URL.');
  }
}

String psLiteral(String value) => "'${value.replaceAll("'", "''")}'";
String get powershell =>
    '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}'
    r'\System32\WindowsPowerShell\v1.0\powershell.exe';

String encodePowerShell(String script) => base64Encode([
  for (final unit in script.codeUnits) ...[unit & 255, unit >> 8],
]);

/// Only the registered per-user Flutter installation may replace itself.
Future<String?> installedFlutterExecutable() async {
  if (!Platform.isWindows) return null;
  final exe = File(Platform.resolvedExecutable).absolute;
  if (exe.uri.pathSegments.last.toLowerCase() != 'modbus_desktop.exe') {
    return null;
  }
  final script =
      '''\$ErrorActionPreference = 'Stop'
\$key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64).OpenSubKey('Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\ModbusConnectorFlutter')
if (\$null -eq \$key) { exit 1 }
\$location = \$key.GetValue('InstallLocation')
if ([string]::IsNullOrWhiteSpace(\$location)) { exit 1 }
if ([IO.Path]::GetFullPath(\$location).TrimEnd('\\') -ne [IO.Path]::GetFullPath(${psLiteral(exe.parent.path)}).TrimEnd('\\')) { exit 1 }
[Console]::Write('installed')
''';
  try {
    final process = await Process.start(powershell, [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      encodePowerShell(script),
    ]);
    final output = process.stdout.transform(utf8.decoder).join();
    unawaited(process.stderr.drain<void>());
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 10));
      return code == 0 && (await output).trim() == 'installed'
          ? exe.path
          : null;
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      await output;
      return null;
    }
  } catch (_) {
    return null;
  }
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();
  @override
  String toString() => 'Update cancelled.';
}

/// An uncommitted helper never installs, even if the app crashes or exits.
String updaterScript(
  Directory work,
  String executable,
  int parentPid,
  String digest,
) =>
    '''
\$ErrorActionPreference = 'Stop'
\$work = ${psLiteral(work.path)}
\$exe = ${psLiteral(executable)}
\$installer = Join-Path \$work 'setup.exe'
\$committed = \$false
try {
    \$parent = Get-Process -Id $parentPid -ErrorAction Stop
    \$null = \$parent.Handle
    [IO.File]::WriteAllText((Join-Path \$work 'ready'), 'ready')
    \$deadline = [DateTime]::UtcNow.AddSeconds(120)
    while (!(Test-Path -LiteralPath (Join-Path \$work 'commit'))) {
        if (\$parent.HasExited -or [DateTime]::UtcNow -gt \$deadline) { throw 'Update was not confirmed.' }
        Start-Sleep -Milliseconds 100
    }
    \$committed = \$true
    if (!\$parent.WaitForExit(120000)) { throw 'The application did not exit. Installation was not changed.' }
    \$others = @(Get-Process -Name 'modbus_desktop' -ErrorAction SilentlyContinue | Where-Object { \$_.Path -eq \$exe })
    if (\$others.Count -gt 0) { throw 'Close other Modbus Connector windows and retry.' }
    if ((Get-FileHash -LiteralPath \$installer -Algorithm SHA256).Hash -ne ${psLiteral(digest)}) { throw 'Installer verification failed.' }
    \$installDir = Split-Path -Parent \$exe
    \$setup = Start-Process -FilePath \$installer -ArgumentList ('/S /D=' + \$installDir) -WorkingDirectory \$work -PassThru -Wait
    if (\$setup.ExitCode -ne 0) { throw ('Installation failed: ' + \$setup.ExitCode) }
    Start-Process -FilePath \$exe -WorkingDirectory \$installDir
    Remove-Item -LiteralPath \$work -Recurse -Force
} catch {
    \$message = \$_.Exception.Message + [Environment]::NewLine + 'Update files: ' + \$work
    [IO.File]::WriteAllText((Join-Path \$work 'error.txt'), \$message)
    if (\$committed) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(\$message, 'Modbus Connector update failed') | Out-Null
    }
    exit 1
}
''';

abstract class UpdateHandoff {
  Future<void> commit();
  Future<void> abort();
}

class WindowsUpdateHandoff implements UpdateHandoff {
  WindowsUpdateHandoff(this.directory, this.process) {
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    exited = process.exitCode.then((code) {
      exitCode = code;
      return code;
    });
  }
  final Directory directory;
  final Process process;
  late final Future<int> exited;
  int? exitCode;
  @override
  Future<void> commit() async {
    if (exitCode != null ||
        await File('${directory.path}/error.txt').exists()) {
      throw const FormatException(
        'The update helper stopped. Please try again.',
      );
    }
    await File('${directory.path}/commit')
        .writeAsString('install', flush: true);
  }

  @override
  Future<void> abort() async {
    if (exitCode == null) process.kill();
    await exited;
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Async streaming keeps progress/cancellation responsive without a Python runtime.
class UpdateInstaller {
  UpdateInstaller({HttpClient Function()? clientFactory})
    : clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() clientFactory;
  HttpClient? _client;
  bool cancelled = false;
  void cancel() {
    cancelled = true;
    _client?.close(force: true);
  }

  void checkCancel() {
    if (cancelled) throw const UpdateCancelled();
  }

  Future<void> download(
    InstallerAsset asset,
    File target,
    void Function(double) progress,
  ) async {
    validateInstallerUrl(asset.url);
    checkCancel();
    final client = _client = clientFactory();
    final partial = File('${target.path}.part');
    RandomAccessFile? output;
    try {
      var uri = asset.url;
      HttpClientResponse? response;
      for (var i = 0; i <= 5; i++) {
        validateInstallerUrl(uri);
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        request.headers.set('Accept', 'application/octet-stream');
        response = await request.close().timeout(const Duration(seconds: 15));
        if (![301, 302, 303, 307, 308].contains(response.statusCode)) break;
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || i == 5) {
          throw const HttpException('Invalid installer redirect.');
        }
        uri = uri.resolve(location);
        validateInstallerUrl(uri);
        // Responses are not reused; closing the client below releases redirect bodies.
      }
      if (response!.statusCode != 200) {
        throw HttpException(
          'Installer download failed: HTTP ${response.statusCode}.',
        );
      }
      checkCancel();
      output = await partial.open(mode: FileMode.write);
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        checkCancel();
        received += chunk.length;
        if (received > asset.size) {
          throw const FormatException('Installer verification failed.');
        }
        await output.writeFrom(chunk);
        progress(received / asset.size);
      }
      await output.close();
      output = null;
      checkCancel();
      final digest = await sha256.bind(partial.openRead()).first;
      final header = await partial.open();
      final magic = await header.read(2);
      await header.close();
      if (received != asset.size ||
          digest.toString() != asset.digest ||
          magic.length != 2 ||
          magic[0] != 77 ||
          magic[1] != 90) {
        throw const FormatException('Installer verification failed.');
      }
      checkCancel();
      await partial.rename(target.path);
    } catch (_) {
      if (cancelled) throw const UpdateCancelled();
      rethrow;
    } finally {
      await output?.close();
      client.close(force: true);
      _client = null;
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<UpdateHandoff> prepare(
    InstallerAsset asset,
    void Function(double) progress,
  ) async {
    final executable = await installedFlutterExecutable();
    if (executable == null) {
      throw const FormatException(
        'Automatic installation requires a Windows installed copy.',
      );
    }
    checkCancel();
    final directory = await Directory.systemTemp.createTemp('modbus-update-');
    WindowsUpdateHandoff? handoff;
    try {
      await download(asset, File('${directory.path}/setup.exe'), progress);
      checkCancel();
      final process = await Process.start(powershell, [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-EncodedCommand',
        encodePowerShell(
          updaterScript(directory, executable, pid, asset.digest),
        ),
      ], workingDirectory: directory.parent.path);
      handoff = WindowsUpdateHandoff(directory, process);
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!await File('${directory.path}/ready').exists()) {
        checkCancel();
        if (handoff.exitCode != null || DateTime.now().isAfter(deadline)) {
          throw const FormatException('Could not start the update helper.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      checkCancel();
      return handoff;
    } catch (_) {
      if (handoff != null) {
        await handoff.abort();
      } else if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      rethrow;
    }
  }
}

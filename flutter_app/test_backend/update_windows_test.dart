import 'dart:convert';
import 'dart:io';

import 'package:modbus_desktop/src/backend/update.dart';
import 'package:test/test.dart';

// Exercise the real PowerShell helper with disposable executables. No registry,
// application installation, network access or real Modbus process is changed.
void main() {
  final shell = Platform.isWindows
      ? powershell
      : '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe';
  for (final commit in [true, false]) {
    test(
      'Windows helper waits for exit and explicit commit=$commit',
      () async {
        final root = Platform.isWindows
            ? await Directory.systemTemp.createTemp('modbus-updater-smoke-')
            : await Directory('/mnt/d/Temp')
                  .createTemp('modbus-updater-smoke-');
        String win(String path) => Platform.isWindows
            ? path
            : 'D:${path.substring('/mnt/d'.length).replaceAll('/', '\\')}';
        final install = '${win(root.path)}\\Installed O\'Brien \$ 中文';
        final work = '${win(root.path)}\\Download O\'Brien \$ 中文';
        final executable = '$install\\modbus_desktop.exe';
        final script = updaterScript(
          Directory(work),
          executable,
          2147483000,
          'HASH_SENTINEL',
        );
        final harness =
            '''
\$ErrorActionPreference = 'Stop'
\$install = ${psLiteral(install)}
\$work = ${psLiteral(work)}
\$exe = ${psLiteral(executable)}
New-Item -ItemType Directory -Path \$install,\$work | Out-Null
\$source = @'
using System;
using System.IO;
using System.Threading;
class App {
    static int Main(string[] args) {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        if (args.Length > 0 && args[0] == "--parent") {
            File.WriteAllText(Path.Combine(dir, "parent-ready"), "ready");
            while (!File.Exists(Path.Combine(dir, "exit-parent"))) Thread.Sleep(50);
        } else if (args.Length > 0 && args[0] == "/S") {
            string command = Environment.CommandLine;
            string target = command.Substring(command.IndexOf("/D=") + 3);
            File.WriteAllText(Path.Combine(target, "installed"), command);
        } else {
            if (!File.Exists(Path.Combine(dir, "installed"))) return 2;
            File.WriteAllText(Path.Combine(dir, "restarted"), "yes");
        }
        return 0;
    }
}
'@
Add-Type -TypeDefinition \$source -OutputAssembly \$exe -OutputType ConsoleApplication
Copy-Item -LiteralPath \$exe -Destination (Join-Path \$work 'setup.exe')
\$hash = (Get-FileHash -LiteralPath (Join-Path \$work 'setup.exe') -Algorithm SHA256).Hash
\$parent = Start-Process -FilePath \$exe -ArgumentList '--parent' -PassThru
\$helper = \$null
function Await-File([string]\$path) {
    \$deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (!(Test-Path -LiteralPath \$path)) {
        if ([DateTime]::UtcNow -gt \$deadline) { throw ('Timed out: ' + \$path) }
        Start-Sleep -Milliseconds 50
    }
}
try {
    Await-File (Join-Path \$install 'parent-ready')
    \$script = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${base64Encode(utf8.encode(script))}'))
    \$script = \$script.Replace('2147483000', [string]\$parent.Id).Replace('HASH_SENTINEL', \$hash)
    \$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(\$script))
    \$helper = Start-Process -FilePath ${psLiteral(Platform.isWindows ? powershell : r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe')} -ArgumentList ('-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + \$encoded) -PassThru
    Await-File (Join-Path \$work 'ready')
    ${commit ? "[IO.File]::WriteAllText((Join-Path \$work 'commit'), 'install')" : ''}
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath (Join-Path \$install 'installed')) { throw 'Installed before parent exit' }
    [IO.File]::WriteAllText((Join-Path \$install 'exit-parent'), 'exit')
    if (!\$parent.WaitForExit(15000)) { throw 'Parent did not exit' }
    if (!\$helper.WaitForExit(20000)) { throw 'Helper did not exit' }
    ${commit ? "Await-File (Join-Path \$install 'restarted')\n    if (\$helper.ExitCode -ne 0) { throw 'Helper failed' }" : "if (Test-Path -LiteralPath (Join-Path \$install 'installed')) { throw 'Installed without commit' }\n    if (\$helper.ExitCode -eq 0) { throw 'Expected unconfirmed helper to abort' }"}
    [Console]::Write('PASS')
} finally {
    if (!\$parent.HasExited) { \$parent.Kill(); \$parent.WaitForExit() }
    if (\$null -ne \$helper -and !\$helper.HasExited) { \$helper.Kill(); \$helper.WaitForExit() }
}
''';
        try {
          final result = await Process.run(
            shell,
            [
              '-NoProfile',
              '-NonInteractive',
              '-EncodedCommand',
              encodePowerShell(harness),
            ],
            stdoutEncoding: null,
            stderrEncoding: null,
            environment: powershellEnvironment(),
            includeParentEnvironment: false,
          ).timeout(const Duration(seconds: 60));
          expect(
            result.exitCode,
            0,
            reason:
                '${utf8.decode(result.stdout as List<int>, allowMalformed: true)}\n${utf8.decode(result.stderr as List<int>, allowMalformed: true)}',
          );
          expect(
            utf8.decode(result.stdout as List<int>, allowMalformed: true),
            contains('PASS'),
          );
        } finally {
          await root.delete(recursive: true);
        }
      },
      skip: !File(shell).existsSync(),
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}

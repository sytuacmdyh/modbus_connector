"""Native Windows process smoke tests; no installed application or registry changes.

Can also run directly with Windows Python (stdlib only).
"""

import base64
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from modbus_connector.update_install import UpdateHandoff, _launch_helper, updater_script


@unittest.skipUnless(sys.platform == 'win32', 'requires Windows PowerShell and .NET')
class WindowsUpdateTests(unittest.TestCase):
    def test_install_waits_for_exit_then_restarts(self):
        self._run_update(commit=True)

    def test_parent_exit_without_commit_never_installs(self):
        self._run_update(commit=False)

    def _run_update(self, *, commit):
        powershell = str(Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0'
                         / 'powershell.exe')
        with tempfile.TemporaryDirectory(prefix='modbus-update-smoke-') as temporary:
            root = Path(temporary)
            install = root / "Installed O'Brien $ 中文"
            work = root / "Download O'Brien $ 中文"
            install.mkdir()
            work.mkdir()
            exe = install / 'ModbusConnector.exe'
            # This disposable executable simulates NSIS and the GUI, including paths with spaces.
            source = r'''
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
            File.WriteAllText(Path.Combine(dir, "restarted"),
                Environment.GetEnvironmentVariable("PYINSTALLER_RESET_ENVIRONMENT") ?? "missing");
        }
        return 0;
    }
}
'''
            compile_script = (
                "$ErrorActionPreference = 'Stop'\nAdd-Type -TypeDefinition @'\n"
                + source + "\n'@ -OutputAssembly '" + str(exe).replace("'", "''")
                + "' -OutputType ConsoleApplication"
            )
            subprocess.run([powershell, '-NoProfile', '-NonInteractive', '-EncodedCommand',
                            base64.b64encode(compile_script.encode('utf-16le')).decode('ascii')],
                           check=True, capture_output=True, timeout=30)
            shutil.copyfile(exe, work / 'setup.exe')
            digest = hashlib.sha256((work / 'setup.exe').read_bytes()).hexdigest()
            parent = subprocess.Popen([str(exe), '--parent'], cwd=install)
            helper = None
            try:
                self._wait_for(install / 'parent-ready')
                script = updater_script(work, exe, parent.pid, digest)
                helper = _launch_helper(
                    Path(powershell),
                    base64.b64encode(script.encode('utf-16le')).decode('ascii'), work,
                )
                self._wait_for(work / 'ready')
                self.assertFalse((install / 'installed').exists())
                if commit:
                    UpdateHandoff(work, helper).commit()
                    time.sleep(0.3)
                    self.assertFalse((install / 'installed').exists())
                (install / 'exit-parent').touch()
                parent.wait(timeout=10)
                result = helper.wait(timeout=30)
                if commit:
                    self.assertEqual(result, 0, (work / 'error.txt').read_text(encoding='utf-8')
                                     if (work / 'error.txt').exists() else '')
                    self._wait_for(install / 'restarted')
                    self.assertEqual((install / 'restarted').read_text(encoding='utf-8'), '1')
                    self.assertIn('/S /D=' + str(install),
                                  (install / 'installed').read_text(encoding='utf-8'))
                    self.assertFalse(work.exists())
                else:
                    self.assertNotEqual(result, 0)
                    self.assertFalse((install / 'installed').exists())
                    self.assertFalse((install / 'restarted').exists())
                    self.assertIn('not confirmed', (work / 'error.txt').read_text(encoding='utf-8'))
            finally:
                for process in (parent, helper):
                    if process is not None and process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)

    def _wait_for(self, path):
        deadline = time.monotonic() + 15
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(path.exists(), str(path))


if __name__ == '__main__':
    unittest.main()

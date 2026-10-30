"""Install, launch, reinstall and uninstall on a disposable Windows CI runner."""
import argparse
import hashlib
import os
import subprocess
import tempfile
import time
import traceback
import winreg
from pathlib import Path

KEY = r'Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnectorFlutter'


def installed():
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, KEY, 0,
                            winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as key:
            return {name: winreg.QueryValueEx(key, name)[0]
                    for name in ('InstallLocation', 'DisplayVersion')}
    except FileNotFoundError:
        return None


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('installer', type=Path)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    if installed():
        raise RuntimeError('Refusing to replace an existing installation; use a clean runner')
    settings = Path.home() / '.modbus_connector' / 'flutter'
    settings.mkdir(parents=True, exist_ok=True)
    sentinel = settings / 'installer-preservation-check.txt'
    sentinel.write_text('Preserve settings and personal templates', encoding='utf-8')
    with tempfile.TemporaryDirectory(prefix='Modbus installer test ') as tmp:
        target = Path(tmp) / 'Application with spaces'
        installer = str(args.installer.resolve())
        # /D must be last and unquoted in NSIS's raw Windows command line.
        command = f'"{installer}" /S /D={target}'
        subprocess.run(command, check=True, timeout=180)
        assert installed() == {'InstallLocation': str(target), 'DisplayVersion': args.version}
        for source in args.bundle.rglob('*'):
            if source.is_file():
                assert digest(source) == digest(target / source.relative_to(args.bundle))
        shortcut = (Path(os.environ['APPDATA']) / 'Microsoft/Windows/Start Menu/Programs'
                    / 'Modbus Connector Flutter/Modbus Connector Flutter.lnk')
        assert shortcut.is_file()
        profile = Path(tmp) / 'Isolated profile'
        profile.mkdir()
        env = dict(os.environ, USERPROFILE=str(profile), HOME=str(profile),
                   MODBUS_FLUTTER_HOME=str(profile / "flutter"))
        process = subprocess.Popen([str(target / 'modbus_desktop.exe')], cwd=target, env=env)
        try:
            time.sleep(10)
            assert process.poll() is None, 'Installed GUI exited during startup'
            title = subprocess.check_output([
                'powershell', '-NoProfile', '-Command',
                f'(Get-Process -Id {process.pid}).MainWindowTitle',
            ], text=True).strip()
            assert 'Modbus Connector Flutter' in title, f'No application window: {title!r}'
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=30)
        extra = target / 'user-created.txt'
        extra.write_text('keep me', encoding='utf-8')
        subprocess.run(command, check=True, timeout=180)
        assert extra.read_text() == 'keep me'
        # Run in place so subprocess waits for the actual uninstall process.
        subprocess.run(f'"{target / "Uninstall.exe"}" /S _?={target}',
                       check=True, timeout=180)
        assert installed() is None
        assert not (target / 'modbus_desktop.exe').exists()
        assert not shortcut.exists()
        assert extra.read_text() == 'keep me'
        assert sentinel.read_text() == 'Preserve settings and personal templates'
    sentinel.unlink()
    print('PASS: payload hashes, registration, shortcuts, GUI startup, reinstall, '
          'uninstall, data preservation')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        if os.environ.get('GITHUB_ACTIONS'):
            details = (traceback.format_exc().replace('%', '%25')
                       .replace('\r', '%0D').replace('\n', '%0A'))
            print(f'::error::{details}', flush=True)
        raise

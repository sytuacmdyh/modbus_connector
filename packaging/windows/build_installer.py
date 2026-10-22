"""Wrap an existing Windows GUI bundle with NSIS; no application rebuild."""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import tempfile
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def nsis_literal(value: str) -> str:
    return value.replace('$', '$$').replace('"', '$\\"')


def build(bundle: Path, version: str, output: Path, compiler: str) -> None:
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Expected MAJOR.MINOR.PATCH")
    bundle = bundle.resolve()
    if not (bundle / "ModbusConnector.exe").is_file():
        raise ValueError("Bundle must contain ModbusConnector.exe")
    files = sorted(p for p in bundle.rglob('*') if p.is_file())
    directories = sorted(
        (p for p in bundle.rglob('*') if p.is_dir()),
        key=lambda p: len(p.parts), reverse=True,
    )
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='modbus-nsis-') as tmp:
        stage = Path(tmp)
        # Delete only shipped files; never recursively delete user-added files.
        def relative(path: Path) -> str:
            return nsis_literal(path.relative_to(bundle).as_posix().replace('/', '\\'))

        manifest = [
            f'Delete "$INSTDIR\\{relative(p)}"'
            for p in files
        ]
        manifest += [
            f'RMDir "$INSTDIR\\{relative(p)}"'
            for p in directories
        ]
        (stage / 'uninstall-files.nsh').write_text('\n'.join(manifest), encoding='utf-8')
        definitions = {
            'VERSION': version, 'BUNDLE': bundle.as_posix(),
            'OUTPUT_FILE': output.as_posix(), 'SOURCE_DIR': ROOT.as_posix(),
            'INSTALLED_KIB': str(sum(p.stat().st_size for p in files) // 1024 + 1),
            'UNINSTALL_FILES': (stage / 'uninstall-files.nsh').as_posix(),
        }
        # Compile-time file paths do not use runtime dollar escaping.
        script = '\n'.join(f'!define {k} `{v}`' for k, v in definitions.items())
        script += '\n' + (ROOT / 'packaging/windows/installer.nsi').read_text(encoding='utf-8')
        source = stage / 'installer.nsi'
        source.write_text(script, encoding='utf-8')
        prefix = '/' if os.name == 'nt' else '-'
        result = subprocess.run([compiler, f'{prefix}INPUTCHARSET', 'UTF8', str(source)],
                                capture_output=True, text=True, errors='replace')
        print(result.stdout)
        if result.returncode:
            raise RuntimeError(f'NSIS failed: {result.stderr}\n{result.stdout[-3000:]}')
    print(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, default=ROOT / 'dist/ModbusConnector')
    parser.add_argument('--version', default=re.search(
        r'__version__ = "([^"]+)"',
        (ROOT / 'src/modbus_connector/__init__.py').read_text(),
    ).group(1))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--makensis', default=shutil.which('makensis') or
                        r'C:\Program Files (x86)\NSIS\makensis.exe')
    args = parser.parse_args()
    output = args.output or ROOT / f'dist/modbus-connector-{args.version}-windows-x64-setup.exe'
    build(args.bundle, args.version, output, args.makensis)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        if os.environ.get('GITHUB_ACTIONS'):
            details = (traceback.format_exc().replace('%', '%25')
                       .replace('\r', '%0D').replace('\n', '%0A'))
            print(f'::error::{details}', flush=True)
        raise

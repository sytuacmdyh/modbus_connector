"""Freeze a native Python bridge and attach it to a built Flutter bundle.

Run with the target platform's Python (Windows builds must run on Windows).
The existing Flutter bundle is retained; only its generated bridge/ is replaced.
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--bundle",
        type=Path,
        required=True,
        help="Flutter Release/ (Windows) or bundle/ (Linux) directory",
    )
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    app_name = "modbus_desktop.exe" if sys.platform == "win32" else "modbus_desktop"
    if not (bundle / app_name).is_file():
        parser.error(f"Build Flutter first: {bundle / app_name} does not exist")
    repo = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="modbus-flutter-bridge-") as directory:
        scratch = Path(directory)
        subprocess.run(
            [
                sys.executable,
                "-m",
                "PyInstaller",
                "--noconfirm",
                "--clean",
                "--onedir",
                "--console",
                "--name",
                "modbus_bridge",
                "--distpath",
                str(scratch / "dist"),
                "--workpath",
                str(scratch / "work"),
                "--specpath",
                str(scratch),
                "--paths",
                str(repo / "src"),
                "--exclude-module",
                "PySide6",
                "--exclude-module",
                "pyqtgraph",
                "--exclude-module",
                "numpy",
                str(repo / "packaging" / "flutter_bridge_entry.py"),
            ],
            check=True,
            cwd=repo,
        )
        target = bundle / "bridge"
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(scratch / "dist" / "modbus_bridge", target)
    print(f"Bridge bundled in {target}")


if __name__ == "__main__":
    main()

"""Build the Flutter desktop bundle and standalone CLI/MCP tools natively."""

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args: str, cwd: Path = ROOT) -> None:
    subprocess.run(args, cwd=cwd, check=True)


def main() -> None:
    platform = {"win32": "windows", "linux": "linux", "darwin": "macos"}[sys.platform]
    flutter = shutil.which("flutter")
    if platform != "macos":
        if not flutter:
            raise SystemExit("Flutter SDK is required; add flutter/bin to PATH")
        version = re.search(
            r'__version__ = "([^"]+)"',
            (ROOT / "src/modbus_connector/__init__.py").read_text(),
        ).group(1)
        app = ROOT / "flutter_app"
        run(flutter, "pub", "get", cwd=app)
        build_name = version.split("-", 1)[0]
        run(
            flutter, "build", platform, "--release", f"--build-name={build_name}",
            f"--dart-define=APP_VERSION={version}", cwd=app,
        )
        source = app / "build" / (
            "windows/x64/runner/Release" if platform == "windows" else "linux/x64/release/bundle"
        )
        target = ROOT / "dist/ModbusConnectorFlutter"
        if target.exists():
            shutil.rmtree(target)
        stale = source / "bridge"
        if stale.exists():
            raise SystemExit(f"Refusing stale Python bridge in Flutter bundle: {stale}")
        shutil.copytree(source, target)
        print(f"Flutter bundle: {target}", flush=True)

    # There is no macOS Flutter runner. Keep the existing headless tools available.
    for tool in ("cli", "mcp"):
        name = f"modbus-connector-{tool}"
        run(
            sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean",
            "--console", "--onefile", "--name", name, "--paths", "src",
            "--paths", "mcp/src", "--collect-data", "modbus_connector.templates",
            "--distpath", "dist-cli", f"packaging/{tool}_entry.py",
        )
        extension = ".exe" if platform == "windows" else ""
        source = ROOT / "dist-cli" / f"{name}{extension}"
        source.replace(source.with_name(f"{name}-{platform}{extension}"))


if __name__ == "__main__":
    main()

"""Protect the Flutter installer boundary and the retained headless entry point."""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "build_installer", ROOT / "packaging/windows/build_installer.py",
)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def test_installer_rejects_legacy_gui_and_incomplete_flutter_bundle(tmp_path):
    (tmp_path / "ModbusConnector.exe").touch()
    with pytest.raises(ValueError, match="modbus_desktop.exe"):
        installer.build(tmp_path, "1.2.3", tmp_path / "setup.exe", "unused")
    (tmp_path / "modbus_desktop.exe").touch()
    with pytest.raises(ValueError, match="flutter_assets"):
        installer.build(tmp_path, "1.2.3", tmp_path / "setup.exe", "unused")


def test_installer_preserves_flutter_identity_and_limits_uninstall(tmp_path, monkeypatch):
    bundle = tmp_path / "Flutter bundle"
    (bundle / "data/flutter_assets").mkdir(parents=True)
    (bundle / "modbus_desktop.exe").write_bytes(b"flutter")
    (bundle / "serialport.dll").write_bytes(b"native serial")
    compiled = []

    def compile_script(command, **kwargs):
        script = Path(command[-1]).read_text(encoding="utf-8")
        manifest = Path(command[-1]).with_name("uninstall-files.nsh").read_text()
        compiled.append((script, manifest))
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

    monkeypatch.setattr(installer.subprocess, "run", compile_script)
    installer.build(bundle, "1.2.3", tmp_path / "setup.exe", "makensis")
    script, manifest = compiled[0]
    assert 'Programs\\ModbusConnectorFlutter"' in script
    assert 'Uninstall\\ModbusConnectorFlutter"' in script
    assert 'Modbus Connector Flutter.lnk" "$INSTDIR\\modbus_desktop.exe"' in script
    assert "ModbusConnector.exe" not in script
    assert 'Delete "$INSTDIR\\serialport.dll"' in manifest
    assert "RMDir /r" not in manifest
    assert "settings.json" not in manifest


def test_package_module_entry_point_runs_cli_without_gui():
    result = subprocess.run(
        [sys.executable, "-m", "modbus_connector", "--help"],
        capture_output=True, text=True, check=True,
    )
    assert "read" in result.stdout and "simulate" in result.stdout
    assert "PySide" not in result.stderr

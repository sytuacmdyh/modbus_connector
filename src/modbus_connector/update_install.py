"""Verified Windows installer downloads and an out-of-process update handoff."""

import base64
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from dataclasses import dataclass
from email.message import Message
from http.client import HTTPResponse
from pathlib import Path
from threading import Event
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from modbus_connector.update_check import ReleaseAsset, UpdateCheckError


class UpdateCancelled(Exception):
    pass


def installed_executable() -> Path | None:
    """Only update the registered per-user installation, never a portable/source copy."""
    if sys.platform != "win32" or not getattr(sys, "frozen", False):
        return None
    import winreg

    executable = Path(sys.executable).resolve()
    if executable.name.lower() != "modbusconnector.exe":
        return None
    try:
        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\CurrentVersion\Uninstall\ModbusConnector",
            0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY,
        ) as key:
            location, _ = winreg.QueryValueEx(key, "InstallLocation")
        if Path(location).resolve() == executable.parent:
            return executable
    except (OSError, TypeError, ValueError):
        pass
    return None


def _validate_url(url: str) -> None:
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or parsed.netloc not in {
        "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
    }):
        raise UpdateCheckError("Unsafe installer download URL.")


class _DownloadRedirects(HTTPRedirectHandler):
    def redirect_request(
        self, req: Request, fp: HTTPResponse, code: int, msg: str,
        headers: Message, newurl: str,
    ) -> Request | None:
        _validate_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download_installer(
    asset: ReleaseAsset, destination: Path, cancel: Event,
    progress: Callable[[int], None],
) -> None:
    """Stream to a partial file; expose an executable only after size/hash validation."""
    _validate_url(asset.url)
    partial = destination.with_suffix(".part")
    digest = hashlib.sha256()
    received = 0
    previous_percent = -1
    try:
        if cancel.is_set():
            raise UpdateCancelled()
        request = Request(asset.url, headers={"Accept": "application/octet-stream"})
        with build_opener(_DownloadRedirects()).open(request, timeout=15) as response:
            if response.status != 200:
                raise UpdateCheckError("Installer download failed: HTTP {status}.",
                                       status=response.status)
            with partial.open("xb") as output:
                while True:
                    if cancel.is_set():
                        raise UpdateCancelled()
                    chunk = response.read(256 * 1024)
                    if not chunk:
                        break
                    received += len(chunk)
                    if received > asset.size:
                        raise UpdateCheckError(
                            "Installer verification failed. Please download again.")
                    digest.update(chunk)
                    output.write(chunk)
                    percent = received * 100 // asset.size
                    if percent != previous_percent:
                        progress(percent)
                        previous_percent = percent
        if cancel.is_set():
            raise UpdateCancelled()
        if received != asset.size or digest.hexdigest() != asset.sha256:
            raise UpdateCheckError("Installer verification failed. Please download again.")
        with partial.open("rb") as downloaded:
            if downloaded.read(2) != b"MZ":
                raise UpdateCheckError("Installer verification failed. Please download again.")
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)


def _ps_literal(value: str | Path) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def updater_script(directory: Path, executable: Path, parent_pid: int, sha256: str) -> str:
    """Use literal PowerShell strings and NSIS's unquoted, final /D argument."""
    return f"""$ErrorActionPreference = 'Stop'
$work = {_ps_literal(directory)}
$exe = {_ps_literal(executable)}
$installer = Join-Path $work 'setup.exe'
$committed = $false
try {{
    $parent = Get-Process -Id {parent_pid} -ErrorAction Stop
    $null = $parent.Handle
    [IO.File]::WriteAllText((Join-Path $work 'ready'), 'ready')
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while (!(Test-Path -LiteralPath (Join-Path $work 'commit'))) {{
        if ($parent.HasExited -or [DateTime]::UtcNow -gt $deadline) {{
            throw 'Update was not confirmed. The installation has not been changed.'
        }}
        Start-Sleep -Milliseconds 100
    }}
    $committed = $true
    if (!$parent.WaitForExit(120000)) {{
        throw 'The application did not exit. The installation has not been changed.'
    }}
    $others = @(Get-Process -Name 'ModbusConnector' -ErrorAction SilentlyContinue |
        Where-Object {{ $_.Path -eq $exe }})
    if ($others.Count -gt 0) {{
        throw 'Close all Modbus Connector instances and retry the update.'
    }}
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne {_ps_literal(sha256)}) {{
        throw 'Installer verification failed. The installation has not been changed.'
    }}
    $installDir = Split-Path -Parent $exe
    $setup = Start-Process -FilePath $installer -ArgumentList ('/S /D=' + $installDir) `
        -WorkingDirectory $work -PassThru -Wait
    if ($setup.ExitCode -ne 0) {{
        throw ('Installation failed (exit code ' + $setup.ExitCode + '). Run setup.exe manually.')
    }}
    $env:PYINSTALLER_RESET_ENVIRONMENT = '1'
    Start-Process -FilePath $exe -WorkingDirectory $installDir
    Remove-Item -LiteralPath $work -Recurse -Force
}} catch {{
    $message = $_.Exception.Message + [Environment]::NewLine + 'Update files: ' + $work
    [IO.File]::WriteAllText((Join-Path $work 'error.txt'), $message)
    if ($committed) {{
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            $message, 'Modbus Connector update failed') | Out-Null
    }}
    exit 1
}}
"""


@dataclass
class UpdateHandoff:
    directory: Path
    process: subprocess.Popen

    def commit(self) -> None:
        if self.process.poll() is not None:
            raise UpdateCheckError("The update helper stopped. Please try again.")
        (self.directory / "commit").write_text("install", encoding="ascii")

    def abort(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        shutil.rmtree(self.directory, ignore_errors=True)


def _launch_helper(powershell: Path, encoded: str, directory: Path) -> subprocess.Popen:
    # PyInstaller's DLL directory is inherited by system executables on Windows.
    dll_directory = None
    if sys.platform == "win32":
        import ctypes

        kernel32 = ctypes.windll.kernel32
        buffer = ctypes.create_unicode_buffer(32768)
        kernel32.GetDllDirectoryW(len(buffer), buffer)
        dll_directory = buffer.value or None
        if not kernel32.SetDllDirectoryW(None):
            raise ctypes.WinError()
    try:
        environment = dict(os.environ)
        bundle = getattr(sys, "_MEIPASS", None)
        if bundle:
            environment["PATH"] = os.pathsep.join(
                entry for entry in environment.get("PATH", "").split(os.pathsep)
                if not Path(entry).is_relative_to(Path(bundle))
            )
        return subprocess.Popen(
            [str(powershell), "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
            cwd=directory.parent, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            # CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP. Windows PowerShell can
            # silently skip -EncodedCommand with DETACHED_PROCESS.
            stderr=subprocess.DEVNULL, creationflags=0x08000000 | 0x00000200,
            env=environment,
        )
    finally:
        if sys.platform == "win32":
            kernel32.SetDllDirectoryW(dll_directory)


def prepare_update(
    asset: ReleaseAsset, executable: Path, cancel: Event, progress: Callable[[int], None],
) -> UpdateHandoff:
    directory = Path(tempfile.mkdtemp(prefix="modbus-update-"))
    handoff = None
    try:
        download_installer(asset, directory / "setup.exe", cancel, progress)
        if cancel.is_set():
            raise UpdateCancelled()
        script = updater_script(directory, executable, os.getpid(), asset.sha256)
        encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
        powershell = (Path(os.environ["SystemRoot"]) / "System32" / "WindowsPowerShell"
                      / "v1.0" / "powershell.exe")
        process = _launch_helper(powershell, encoded, directory)
        handoff = UpdateHandoff(directory, process)
        deadline = time.monotonic() + 15
        while not (directory / "ready").exists():
            if cancel.wait(0.05):
                raise UpdateCancelled()
            if process.poll() is not None or time.monotonic() > deadline:
                raise UpdateCheckError("Could not start the update helper. Please try again.")
        if cancel.is_set():
            raise UpdateCancelled()
        return handoff
    except BaseException:
        if handoff is not None:
            handoff.abort()
        else:
            shutil.rmtree(directory, ignore_errors=True)
        raise

import hashlib
import io
import subprocess
from threading import Event
from types import SimpleNamespace

import pytest

from modbus_connector import update_install
from modbus_connector.update_check import ReleaseAsset, UpdateCheckError
from modbus_connector.update_install import (
    UpdateCancelled,
    UpdateHandoff,
    download_installer,
    prepare_update,
)

PAYLOAD = b'MZ' + b'installer payload' * 40000
ASSET = ReleaseAsset(
    'https://github.com/sytuacmdyh/modbus_connector/releases/download/v1.0.0/setup.exe',
    len(PAYLOAD), hashlib.sha256(PAYLOAD).hexdigest(),
)


@pytest.fixture
def response(monkeypatch):
    state = SimpleNamespace(body=PAYLOAD, status=200, urls=[])

    def open_url(request, timeout):
        state.urls.append(request.full_url)
        assert timeout == 15
        stream = io.BytesIO(state.body)
        stream.status = state.status
        return stream

    monkeypatch.setattr(update_install, 'build_opener',
                        lambda *handlers: SimpleNamespace(open=open_url))
    return state


def test_verified_download(response, tmp_path):
    destination = tmp_path / 'setup.exe'
    progress = []
    download_installer(ASSET, destination, Event(), progress.append)
    assert destination.read_bytes() == PAYLOAD
    assert progress[-1] == 100
    assert progress == sorted(set(progress))
    assert not destination.with_suffix('.part').exists()


@pytest.mark.parametrize('body', [PAYLOAD[:-1], PAYLOAD + b'x', b'XX' + PAYLOAD[2:]],
                         ids=['truncated', 'oversized', 'invalid-executable'])
def test_corrupt_download_never_becomes_executable(response, tmp_path, body):
    response.body = body
    destination = tmp_path / 'setup.exe'
    with pytest.raises(UpdateCheckError, match='verification failed'):
        download_installer(ASSET, destination, Event(), lambda value: None)
    assert list(tmp_path.iterdir()) == []


def test_cancellation_removes_partial_download(response, tmp_path):
    cancel = Event()
    with pytest.raises(UpdateCancelled):
        download_installer(ASSET, tmp_path / 'setup.exe', cancel, lambda value: cancel.set())
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize('url', [
    'http://github.com/file.exe', 'https://evil.example/file.exe',
    'https://github.com@evil.example/file.exe', 'https://github.com.evil.example/file.exe',
])
def test_unsafe_url_rejected_before_network(response, tmp_path, url):
    with pytest.raises(UpdateCheckError, match='Unsafe'):
        download_installer(ReleaseAsset(url, 1, '0' * 64), tmp_path / 'setup.exe',
                           Event(), lambda value: None)
    assert response.urls == []
    with pytest.raises(UpdateCheckError, match='Unsafe'):
        update_install._DownloadRedirects().redirect_request(None, None, 302, '', {}, url)


def test_http_failure_removes_download(response, tmp_path):
    response.status = 503
    with pytest.raises(UpdateCheckError, match='download failed'):
        download_installer(ASSET, tmp_path / 'setup.exe', Event(), lambda value: None)
    assert list(tmp_path.iterdir()) == []


class FakeProcess:
    def __init__(self, returncode=None):
        self.returncode = returncode
        self.terminated = False

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = -1

    def wait(self, timeout):
        return self.returncode


@pytest.mark.parametrize('ready', [True, False])
def test_helper_must_acknowledge_before_handoff(response, tmp_path, monkeypatch, ready):
    work = tmp_path / 'update'
    work.mkdir()
    monkeypatch.setattr(update_install.tempfile, 'mkdtemp', lambda **kwargs: str(work))
    monkeypatch.setenv('SystemRoot', 'C:/Windows')
    process = FakeProcess(None if ready else 1)

    def launch(command, **kwargs):
        assert command[-2] == '-EncodedCommand'
        assert kwargs['cwd'] == work.parent
        assert kwargs['stdin'] == subprocess.DEVNULL
        assert (work / 'setup.exe').read_bytes() == PAYLOAD
        if ready:
            (work / 'ready').touch()
        return process

    monkeypatch.setattr(update_install.subprocess, 'Popen', launch)
    if ready:
        handoff = prepare_update(ASSET, tmp_path / 'ModbusConnector.exe', Event(), lambda p: None)
        assert not (work / 'commit').exists()
        handoff.commit()
        assert (work / 'commit').exists()
        handoff.abort()
        assert process.terminated
    else:
        with pytest.raises(UpdateCheckError, match='Could not start'):
            prepare_update(ASSET, tmp_path / 'ModbusConnector.exe', Event(), lambda p: None)
    assert not work.exists()


def test_dead_helper_cannot_commit(tmp_path):
    handoff = UpdateHandoff(tmp_path, FakeProcess(1))
    with pytest.raises(UpdateCheckError, match='helper stopped'):
        handoff.commit()
    assert not (tmp_path / 'commit').exists()


def test_source_run_cannot_update_installation():
    assert update_install.installed_executable() is None


def test_strict_settings_save_reports_failure(tmp_path, monkeypatch):
    from pathlib import Path

    from modbus_connector.settings_store import save_settings

    def fail(*args, **kwargs):
        raise OSError('disk full')

    monkeypatch.setattr(Path, 'write_text', fail)
    save_settings({}, tmp_path / 'settings.json')
    with pytest.raises(OSError, match='disk full'):
        save_settings({}, tmp_path / 'settings.json', strict=True)

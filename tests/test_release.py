"""Release safety and retry behavior against a real local Git remote."""

import importlib.util
import subprocess
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location(
    "release", Path(__file__).parents[1] / "packaging" / "release.py",
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


@pytest.fixture()
def repo(tmp_path, monkeypatch):
    root = tmp_path / "checkout"
    root.mkdir()
    monkeypatch.setattr(release, "ROOT", root)
    git = release.git
    git("init", "-b", "main")
    git("config", "user.name", "Release test")
    git("config", "user.email", "test@example.invalid")
    git("config", "commit.gpgsign", "false")
    git("config", "tag.gpgsign", "false")
    path = root / release.VERSION_FILE
    path.parent.mkdir(parents=True)
    path.write_text('__version__ = "0.1.0"\n', encoding="utf-8")
    git("add", ".")
    git("commit", "-m", "feat: initial")
    git("tag", "v0.1.0")
    remote = tmp_path / "origin.git"
    git("init", "--bare", str(remote))
    git("remote", "add", "origin", str(remote))
    git("push", "origin", "main", "v0.1.0")
    return git, path, remote


def publish(**kwargs):
    return release.publish("0.1.1", "origin", dry_run=False, resume=False, **kwargs)


def test_publish_updates_only_version_and_pushes_matching_annotated_tag(repo):
    git, path, remote = repo
    head = publish()
    assert path.read_text() == '__version__ = "0.1.1"\n'
    assert git("status", "--porcelain") == ""
    assert git("diff-tree", "--no-commit-id", "--name-only", "-r", head) == release.VERSION_FILE
    assert git("cat-file", "-t", "v0.1.1") == "tag"
    assert git("rev-parse", "v0.1.1^{commit}") == head
    assert git("--git-dir", str(remote), "rev-parse", "main") == head
    assert git("--git-dir", str(remote), "rev-parse", "v0.1.1^{commit}") == head


def test_preview_leaves_local_and_remote_unchanged(repo):
    git, path, remote = repo
    before = git("rev-parse", "HEAD"), path.read_bytes(), git("ls-remote", "origin")
    release.publish("0.1.1", "origin", dry_run=True, resume=False)
    assert (git("rev-parse", "HEAD"), path.read_bytes(), git("ls-remote", "origin")) == before
    assert git("tag", "--list", "v0.1.1") == ""


@pytest.mark.parametrize("staged", [False, True])
def test_dirty_work_is_not_committed(repo, staged):
    git, path, remote = repo
    path.write_text('__version__ = "0.2.0"\n')
    if staged:
        git("add", ".")
    before = git("status", "--porcelain"), git("ls-remote", "origin")
    with pytest.raises(ValueError, match="未提交"):
        publish()
    assert (git("status", "--porcelain"), git("ls-remote", "origin")) == before


@pytest.mark.parametrize("version", ["0.1.0", "0.0.9", "01.2.3", "0.1.1-rc1", "../bad"])
def test_invalid_old_or_duplicate_version_rejected(repo, version):
    git, path, remote = repo
    before = git("rev-parse", "HEAD")
    with pytest.raises(ValueError):
        release.publish(version, "origin", dry_run=False, resume=False)
    assert git("rev-parse", "HEAD") == before


def test_remote_ahead_is_rejected_before_changing_version(repo, tmp_path):
    git, path, remote = repo
    other = tmp_path / "other"
    git("clone", "--branch", "main", str(remote), str(other))
    git("-C", str(other), "-c", "user.name=Test", "-c", "user.email=t@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "remote work")
    git("-C", str(other), "push", "origin", "main")
    with pytest.raises(ValueError, match="远端 main"):
        publish()
    assert path.read_text() == '__version__ = "0.1.0"\n'


def test_push_failure_can_resume_without_retagging(repo, monkeypatch):
    git, path, remote = repo

    def fail_push(*args):
        if args[0] == "push":
            raise subprocess.CalledProcessError(1, ["git", *args])
        return git(*args)

    monkeypatch.setattr(release, "git", fail_push)
    with pytest.raises(subprocess.CalledProcessError):
        publish()
    tag = git("rev-parse", "v0.1.1")
    head = git("rev-parse", "HEAD")
    assert "refs/tags/v0.1.1" not in git("ls-remote", "origin")
    monkeypatch.setattr(release, "git", git)
    assert release.publish("0.1.1", "origin", dry_run=False, resume=True) == head
    assert git("rev-parse", "v0.1.1") == tag
    assert git("--git-dir", str(remote), "rev-parse", "main") == head


def test_resume_rejects_changed_head(repo):
    git, path, remote = repo
    publish()
    git("commit", "--allow-empty", "-m", "later work")
    with pytest.raises(ValueError, match="HEAD"):
        release.publish("0.1.1", "origin", dry_run=False, resume=True)


@pytest.mark.parametrize("state", ["pending", "failed", "missing", "wrong_commit", "complete"])
def test_completion_requires_exact_successful_tag_run_and_all_assets(monkeypatch, state):
    run = {
        "head_sha": "other" if state == "wrong_commit" else "sha",
        "head_branch": "v0.1.1", "status": "in_progress" if state == "pending" else "completed",
        "conclusion": "failure" if state == "failed" else "success",
        "html_url": "https://github.com/owner/repo/actions/runs/1",
    }
    assets = [{"name": name, "size": 1, "state": "uploaded"}
              for name in sorted(release.expected_assets("0.1.1"))]
    if state == "missing":
        assets.pop()
    data = {"draft": False, "prerelease": False, "body": "Notes", "assets": assets,
            "html_url": "https://github.com/owner/repo/releases/tag/v0.1.1"}
    monkeypatch.setattr(release, "api", lambda repo, path:
                        {"workflow_runs": [run]} if path.startswith("actions/") else data)
    if state in ("failed", "missing"):
        with pytest.raises(RuntimeError):
            release.check_release("owner/repo", "0.1.1", "sha")
    else:
        assert release.check_release("owner/repo", "0.1.1", "sha") == (state == "complete")


def test_beta_publish_from_develop(repo):
    git, path, remote = repo
    git("checkout", "-b", "develop")
    git("push", "-u", "origin", "develop")
    head = release.publish("0.1.1-beta.1", "origin", dry_run=False, resume=False)
    assert path.read_text() == '__version__ = "0.1.1-beta.1"\n'
    assert git("rev-parse", "v0.1.1-beta.1^{commit}") == head
    assert git("--git-dir", str(remote), "rev-parse", "develop") == head


def test_stable_publish_rejects_develop_branch(repo):
    git, path, remote = repo
    git("checkout", "-b", "develop")
    git("push", "-u", "origin", "develop")
    with pytest.raises(ValueError, match="main"):
        release.publish("0.1.1", "origin", dry_run=False, resume=False)


def test_beta_completion_expects_prerelease_release(monkeypatch):
    run = {
        "head_sha": "sha",
        "head_branch": "v0.1.1-beta.1",
        "status": "completed",
        "conclusion": "success",
        "html_url": "https://github.com/owner/repo/actions/runs/1",
    }
    assets = [{"name": name, "size": 1, "state": "uploaded"}
              for name in sorted(release.expected_assets("0.1.1-beta.1"))]
    data = {"draft": False, "prerelease": True, "body": "Notes", "assets": assets,
            "html_url": "https://github.com/owner/repo/releases/tag/v0.1.1-beta.1"}
    monkeypatch.setattr(release, "api", lambda repo, path:
                        {"workflow_runs": [run]} if path.startswith("actions/") else data)
    assert release.check_release("owner/repo", "0.1.1-beta.1", "sha")

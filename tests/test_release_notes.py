"""Release ranges must exclude future work and tags on unrelated branches."""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location(
    "release_notes", Path(__file__).parents[1] / "packaging" / "update_release_notes.py",
)
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


@pytest.fixture()
def repo(tmp_path, monkeypatch):
    monkeypatch.setattr(notes, "ROOT", tmp_path)
    notes.git("init", "-b", "main")
    notes.git("config", "user.name", "Release test")
    notes.git("config", "user.email", "test@example.invalid")
    return notes.git


def commit(repo, subject):
    repo("-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", subject)


def test_summary_uses_previous_reachable_stable_tag(repo):
    commit(repo, "feat: Old change")
    repo("tag", "v0.1.0")
    repo("checkout", "-b", "unrelated")
    commit(repo, "feat: Unrelated change")
    repo("tag", "v9.0.0")
    repo("checkout", "main")
    commit(repo, "feat(templates): New templates")
    repo("tag", "v0.2.0-rc.1")
    commit(repo, "fix: New templates")
    commit(repo, "chore(release): 发布0.2.0版本")
    repo("tag", "v0.2.0")
    commit(repo, "feat: Future change")
    body = notes.generate_notes("v0.2.0", "owner/repo")
    assert body.count("- New templates") == 1
    assert "compare/v0.1.0...v0.2.0" in body
    assert all(text not in body for text in ("Old change", "Unrelated", "Future", "发布", "rc.1"))


def test_first_release_is_short_and_keeps_one_history_link(repo):
    for i in range(15):
        commit(repo, f"fix: Change {i}")
    repo("tag", "v0.1.0")
    body = notes.generate_notes("v0.1.0", "owner/repo")
    assert body.count("\n- ") == 10
    assert "Change 14" in body and "Change 0\n" not in body
    assert "首个版本" in body
    assert body.count("https://") == 1
    assert "/commits/v0.1.0" in body


def test_partial_release_tag_does_not_hide_changes(repo):
    commit(repo, "feat: Old change")
    repo("tag", "v0.1.0")
    commit(repo, "feat: Automatic updater")
    repo("tag", "v0.1.1")
    commit(repo, "fix: Release checks")
    repo("tag", "v0.1.2")
    body = notes.generate_notes("v0.1.2", "owner/repo", published_tags={"v0.1.0"})
    assert "Automatic updater" in body and "Release checks" in body
    assert "Old change" not in body
    assert "compare/v0.1.0...v0.1.2" in body


def test_version_noise_removed_without_hiding_release_work():
    assert notes.summarize([
        "chore(release): 发布0.15.0版本", "Bump version to 0.15.0",
        "chore(release): 修复发布脚本", "fix(ci): 修复发布脚本", "feat!: New behavior",
    ]) == ["修复发布脚本", "New behavior"]


def test_preview_needs_no_token_and_does_not_write(repo, monkeypatch):
    commit(repo, "feat: First change")
    repo("tag", "v0.1.0")
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.setenv("GITHUB_REPOSITORY", "owner/repo")
    result = subprocess.run(
        [sys.executable, str(Path(notes.__file__)), "--tag", "../bad", "--preview"],
        capture_output=True, text=True,
    )
    assert result.returncode == 2
    monkeypatch.setattr("sys.argv", ["notes", "--tag", "v0.1.0", "--preview"])
    monkeypatch.setattr(notes, "sync_notes", lambda *a, **kw: pytest.fail("unexpected write"))
    notes.main()

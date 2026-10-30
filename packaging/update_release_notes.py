"""Summarize release commits and replace existing release descriptions."""

import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
MAX_ITEMS = 10
TAG = re.compile(
    r"v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-beta\.(?:0|[1-9]\d*))?",
)


def git(*args: str) -> str:
    return subprocess.check_output(
        ["git", *args], cwd=ROOT, text=True, encoding="utf-8",
    ).strip()


def release_tags(*args: str) -> list[str]:
    return [tag for tag in git("tag", "--sort=-version:refname", *args).splitlines()
            if TAG.fullmatch(tag)]


def summarize(subjects: list[str]) -> list[str]:
    summaries = []
    for subject in subjects:
        match = re.fullmatch(r"(\w+)(?:\(([^)]+)\))?!?:\s*(.+)", subject)
        if match:
            kind, scope, subject = match.groups()
            if kind == "chore" and scope == "release" and re.fullmatch(
                r"(?:(?:发布|更新|升级|提升|同步)\s*)?"
                r"v?\d+\.\d+\.\d+(?:-beta\.\d+)?(?:版本)?",
                subject,
            ):
                continue
        if re.match(r"bump (?:version|.+ version)\b", subject, re.IGNORECASE):
            continue
        if subject not in summaries:
            summaries.append(subject)
    return summaries


def generate_notes(tag: str, repository: str, *, published_tags: set[str] | None = None) -> str:
    # Only consider earlier tags reachable from this release, not newer or sibling branches.
    commit = git("rev-parse", f"{tag}^{{commit}}")
    previous = next((candidate for candidate in release_tags("--merged", tag)
                     if git("rev-parse", f"{candidate}^{{commit}}") != commit
                     and (published_tags is None or candidate in published_tags)), None)
    revision = f"{previous}..{tag}" if previous else tag
    subjects = git("log", "--no-merges", "--format=%s", revision).splitlines()
    summaries = summarize(subjects)
    lines = ["## 更新内容", ""]
    if not previous:
        lines += [f"首个版本，以下为最近 {min(len(summaries), MAX_ITEMS)} 项提交摘要。", ""]
    for summary in summaries[:MAX_ITEMS]:
        escaped = re.sub(r"([\\`*_{}\[\]<>])", r"\\\1", summary)
        lines.append(f"- {escaped}")
    if not summaries:
        lines.append("- 常规版本更新。")
    if previous and len(summaries) > MAX_ITEMS:
        lines += ["", f"其余 {len(summaries) - MAX_ITEMS} 项变更见完整提交记录。"]
    path = f"compare/{previous}...{tag}" if previous else f"commits/{tag}"
    lines += ["", f"[完整变更](https://github.com/{repository}/{path})"]
    return "\n".join(lines)


def completed_release_tags(repository: str) -> set[str]:
    """A partial matrix upload has no finalized notes and is not a release base."""
    request = Request(
        f"https://api.github.com/repos/{repository}/releases?per_page=100",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
            "User-Agent": "ModbusConnector-release-notes",
        },
    )
    with urlopen(request, timeout=30) as response:
        releases = json.load(response)
    return {release["tag_name"] for release in releases
            if not release.get("draft") and (release.get("body") or "").strip()}


def sync_notes(tag: str, title: str, body: str, *, missing_ok: bool) -> None:
    repository = os.environ["GITHUB_REPOSITORY"]
    base = f"https://api.github.com/repos/{repository}/releases"
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
        "User-Agent": "ModbusConnector-release-notes",
        "X-GitHub-Api-Version": "2026-03-10",
    }
    try:
        with urlopen(Request(f"{base}/tags/{quote(tag, safe='')}", headers=headers),
                     timeout=30) as response:
            release = json.load(response)
    except HTTPError as exc:
        if missing_ok and exc.code == 404:
            print(f"{tag}: not published yet; skipped")
            return
        raise
    if release["name"] == title and release["body"] == body:
        print(f"{tag}: notes already up to date")
        return
    payload = json.dumps({"name": title, "body": body}, ensure_ascii=False).encode("utf-8")
    headers["Content-Type"] = "application/json"
    with urlopen(Request(f"{base}/{release['id']}", data=payload, headers=headers,
                         method="PATCH"), timeout=30) as response:
        updated = json.load(response)
    if updated["name"] != title or updated["body"] != body:
        raise RuntimeError(f"{tag}: release notes did not match the requested content")
    print(f"{tag}: title and notes updated")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="Update one release; default: all local release tags")
    parser.add_argument("--preview", action="store_true", help="Print notes without network access")
    args = parser.parse_args()
    if args.tag and not TAG.fullmatch(args.tag):
        parser.error("tag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-beta.N")
    tags = [args.tag] if args.tag else release_tags()
    if not tags:
        parser.error("no release tags found")
    repository = os.environ["GITHUB_REPOSITORY"]
    published_tags = None if args.preview else completed_release_tags(repository)
    for tag in tags:
        body = generate_notes(tag, repository, published_tags=published_tags)
        if args.preview:
            print(f"# {tag}\n\n{body}\n")
        else:
            sync_notes(tag, tag, body, missing_ok=args.tag is None)


if __name__ == "__main__":
    main()

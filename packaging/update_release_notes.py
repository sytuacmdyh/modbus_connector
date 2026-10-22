"""Replace existing release titles/bodies from reviewed, versioned Markdown."""

import argparse
import json
import os
import re
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

NOTES = Path(__file__).resolve().parents[1] / "docs" / "releases"
TAG = re.compile(r"v\d+\.\d+\.\d+")


def read_notes(path: Path) -> tuple[str, str]:
    text = path.read_text(encoding="utf-8").strip()
    title, _, body = text.partition("\n")
    if not title.startswith(f"# {path.stem} ") or not body.strip():
        raise ValueError(f"{path}: expected a version heading and release body")
    return title.removeprefix("# ").strip(), body.strip()


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
    parser.add_argument(
        "--tag", help="Update one existing release; default: all documented releases",
    )
    parser.add_argument(
        "--check", action="store_true", help="Validate notes without network access",
    )
    args = parser.parse_args()
    if args.tag and not TAG.fullmatch(args.tag):
        parser.error("tag must be vMAJOR.MINOR.PATCH")
    paths = ([NOTES / f"{args.tag}.md"] if args.tag else
             sorted(p for p in NOTES.glob("v*.md") if TAG.fullmatch(p.stem)))
    if not paths:
        parser.error("no release notes found")
    # Validate the entire batch before changing any remote release.
    notes = [(path.stem, *read_notes(path)) for path in paths]
    for tag, title, body in notes:
        if args.check:
            print(f"{tag}: notes valid")
        else:
            sync_notes(tag, title, body, missing_ok=args.tag is None)


if __name__ == "__main__":
    main()

"""Publish a stable GitHub release with Git and Python's standard library."""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = "src/modbus_connector/__init__.py"
VERSION = re.compile(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)")


def git(*args: str) -> str:
    return subprocess.check_output(
        ["git", *args], cwd=ROOT, text=True, encoding="utf-8",
    ).strip()


def version_tuple(value: str) -> tuple[int, ...]:
    if not VERSION.fullmatch(value):
        raise ValueError("版本号必须为 MAJOR.MINOR.PATCH，例如 0.15.1。")
    return tuple(map(int, value.split(".")))


def github_repository(remote: str) -> str:
    url = git("remote", "get-url", remote)
    if git("remote", "get-url", "--push", remote) != url:
        raise ValueError("发布 remote 的 fetch 和 push 地址必须一致。")
    match = re.fullmatch(
        r"(?:git@github\.com:|https://github\.com/|ssh://git@github\.com/)"
        r"([\w.-]+/[\w.-]+?)(?:\.git)?", url,
    )
    if not match:
        raise ValueError("发布 remote 必须指向 github.com 仓库。")
    return match[1]


def publish(version: str, remote: str, *, dry_run: bool, resume: bool) -> str:
    wanted = version_tuple(version)
    tag = f"v{version}"
    if git("status", "--porcelain"):
        raise ValueError("工作区或暂存区有未提交变更，请先提交后再发布。")
    if git("branch", "--show-current") != "main":
        raise ValueError("请在 main 分支发布。")
    path = ROOT / VERSION_FILE
    source = path.read_text(encoding="utf-8")
    match = re.search(r'^__version__ = "([^"]+)"$', source, re.MULTILINE)
    if match is None:
        raise ValueError("未找到应用版本号。")
    current = match[1]
    refs = {ref: sha for sha, ref in
            (line.split() for line in git("ls-remote", remote, "refs/heads/main",
                                         "refs/tags/v*").splitlines())}
    remote_head = refs.get("refs/heads/main")
    if not remote_head:
        raise ValueError("远端 main 不存在。")
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", remote_head, "HEAD"], cwd=ROOT,
        capture_output=True,
    )
    if ancestor.returncode:
        raise ValueError("远端 main 尚未包含在本地历史中，请先 fetch 并整合远端更新。")
    head = git("rev-parse", "HEAD")
    local_tag = tag in git("tag", "--list", tag).splitlines()
    remote_tag = refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}"))
    if resume:
        if current != version or not local_tag or git("rev-parse", f"{tag}^{{commit}}") != head:
            raise ValueError("续传要求版本号匹配，且本地发布标签指向当前 HEAD。")
        if remote_tag and remote_tag != head:
            raise ValueError("远端同名标签指向其他提交，拒绝覆盖。")
    else:
        if local_tag or remote_tag:
            raise ValueError("发布标签已存在；续传同一发布请使用 --resume。")
        versions = [version_tuple(ref.removeprefix("refs/tags/v")) for ref in refs
                    if ref.startswith("refs/tags/v")
                    and VERSION.fullmatch(ref.removeprefix("refs/tags/v"))]
        if wanted < version_tuple(current) or (versions and wanted <= max(versions)):
            raise ValueError("新版本必须高于已发布版本，且不能低于当前源码版本。")
    print(f"版本：{current} → {version}；标签：{tag}；远端：{remote}", flush=True)
    if dry_run:
        print("预览完成：未修改文件、提交、标签或远端。", flush=True)
        return head
    if not resume:
        if current != version:
            path.write_text(source[:match.start(1)] + version + source[match.end(1):],
                            encoding="utf-8")
            git("add", "--", VERSION_FILE)
            git("commit", "-m", f"chore(release): 发布{version}版本")
        head = git("rev-parse", "HEAD")
        git("tag", "-a", tag, "-m", f"发布 {tag}")
    # No force: branch and tag either advance together or neither is published.
    try:
        git("push", "--atomic", remote, "HEAD:refs/heads/main", f"refs/tags/{tag}")
    except subprocess.CalledProcessError:
        print(f"推送失败，本地提交和标签已保留。修复后运行：\n"
              f"python packaging/release.py {version} --remote {remote} --resume", file=sys.stderr)
        raise
    print(f"已推送 {tag}（{head[:12]}），等待 GitHub Actions 构建。", flush=True)
    return head


def api(repository: str, path: str) -> dict:
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "ModbusConnector-release"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(f"https://api.github.com/repos/{repository}/{path}", headers=headers)
    try:
        with urlopen(request, timeout=30) as response:
            return json.load(response)
    except HTTPError as exc:
        if exc.code == 404:
            return {}
        raise RuntimeError(f"GitHub API 返回 HTTP {exc.code}；可稍后用 --status 查询。") from exc


def expected_assets(version: str) -> set[str]:
    return {
        "ModbusConnector.dmg", "modbus-connector-windows.zip", "modbus-connector-linux.zip",
        "ModbusConnector.AppImage", f"modbus-connector_{version}_amd64.deb",
        f"modbus-connector-{version}-windows-x64-setup.exe",
    } | {f"modbus-connector-{tool}-{suffix}" for tool in ("cli", "mcp")
         for suffix in ("macos", "linux", "windows.exe")}


def check_release(repository: str, version: str, head: str) -> bool:
    tag = f"v{version}"
    data = api(repository, f"actions/workflows/build.yml/runs?event=push&branch={tag}&per_page=20")
    run = next((run for run in data.get("workflow_runs", [])
                if run["head_sha"] == head and run["head_branch"] == tag), None)
    if not run:
        print(f"{tag}：等待标签构建进入队列。", flush=True)
        return False
    print(f"{tag}：{run['status']} / {run.get('conclusion') or 'pending'}\n{run['html_url']}",
          flush=True)
    if run["status"] != "completed":
        return False
    if run["conclusion"] != "success":
        raise RuntimeError("标签构建未成功，请检查上面的 Actions 链接；不要重建或移动发布标签。")
    release = api(repository, f"releases/tags/{tag}")
    assets = {asset["name"] for asset in release.get("assets", [])
              if asset.get("size", 0) > 0 and asset.get("state") == "uploaded"}
    missing = expected_assets(version) - assets
    if (not release or release.get("draft") or release.get("prerelease")
            or not release.get("body", "").strip() or missing):
        raise RuntimeError("构建成功但发布内容不完整；缺少产物：" + ", ".join(sorted(missing)))
    print(f"发布完成：{release['html_url']}\n"
          f"已验证 {len(expected_assets(version))} 个产物和更新说明。",
          flush=True)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="新版本号，例如 0.15.1")
    parser.add_argument("--remote", default="origin")
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--dry-run", action="store_true", help="仅检查发布条件，不做修改")
    actions.add_argument("--status", action="store_true", help="仅查询已有标签的构建及发布结果")
    actions.add_argument("--resume", action="store_true", help="续传指向当前提交的已有本地标签")
    parser.add_argument("--no-wait", action="store_true", help="推送后返回，不等待构建完成")
    parser.add_argument("--timeout", type=int, default=1800, help="等待构建的秒数，默认 1800")
    args = parser.parse_args()
    try:
        version_tuple(args.version)
        if args.timeout <= 0:
            raise ValueError("等待时间必须大于零。")
        repository = github_repository(args.remote)
        if args.status:
            check_release(repository, args.version, git("rev-parse", f"v{args.version}^{{commit}}"))
            return 0
        head = publish(args.version, args.remote, dry_run=args.dry_run, resume=args.resume)
        if args.dry_run or args.no_wait:
            return 0
        deadline = time.monotonic() + args.timeout
        while True:
            if check_release(repository, args.version, head):
                return 0
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("等待超时，远端构建仍会继续；请用 --status 查询。")
            time.sleep(min(60, remaining))
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"发布未完成：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

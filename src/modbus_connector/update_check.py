"""Manual GitHub release lookup, independent of Qt and user configuration."""

import json
import re
from dataclasses import dataclass
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from modbus_connector import __version__

REPOSITORY = "sytuacmdyh/modbus_connector"
RELEASES_URL = f"https://github.com/{REPOSITORY}/releases"
LATEST_RELEASE_API = f"https://api.github.com/repos/{REPOSITORY}/releases/latest"
_MAX_RESPONSE_BYTES = 1024 * 1024


class UpdateCheckError(Exception):
    def __init__(self, message_key: str, **params: object) -> None:
        super().__init__(message_key)
        self.message_key = message_key
        self.params = params


def version_tuple(version: str) -> tuple[int, int, int]:
    """Accept stable release tags only; compare numbers rather than strings."""
    match = re.fullmatch(r"v?([0-9]+)\.([0-9]+)\.([0-9]+)", version)
    if match is None:
        raise UpdateCheckError("Unsupported release version: {version}", version=version)
    return int(match[1]), int(match[2]), int(match[3])


@dataclass(frozen=True)
class ReleaseAsset:
    url: str
    size: int
    sha256: str


@dataclass(frozen=True)
class ReleaseInfo:
    tag: str
    notes: str
    installer: ReleaseAsset | None = None

    @property
    def url(self) -> str:
        return f"{RELEASES_URL}/tag/{self.tag}"

    def is_newer_than(self, current: str) -> bool:
        return version_tuple(self.tag) > version_tuple(current)


def check_for_update() -> ReleaseInfo | None:
    """Return the latest stable release, or None when GitHub returns 404."""
    request = Request(LATEST_RELEASE_API, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": f"ModbusConnector/{__version__}",
        "X-GitHub-Api-Version": "2026-03-10",
    })
    try:
        with urlopen(request, timeout=10) as response:
            raw = response.read(_MAX_RESPONSE_BYTES + 1)
    except HTTPError as exc:
        if exc.code == 404:
            return None
        if exc.code in (403, 429):
            raise UpdateCheckError(
                "GitHub denied the request or rate limit exceeded. Try later."
            ) from exc
        raise UpdateCheckError("GitHub request failed: HTTP {status}.", status=exc.code) from exc
    except (OSError, URLError) as exc:
        raise UpdateCheckError("Could not reach GitHub: {detail}", detail=str(exc)) from exc
    if len(raw) > _MAX_RESPONSE_BYTES:
        raise UpdateCheckError("Invalid GitHub release response.")
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeError) as exc:
        raise UpdateCheckError("Invalid GitHub release response.") from exc
    if (
        not isinstance(data, dict)
        or data.get("draft") is not False
        or data.get("prerelease") is not False
        or not isinstance(data.get("tag_name"), str)
        or not isinstance(data.get("body", ""), (str, type(None)))
    ):
        raise UpdateCheckError("Invalid GitHub release response.")
    version_tuple(data["tag_name"])
    tag = data["tag_name"]
    name = f"modbus-connector-{tag.removeprefix('v')}-windows-x64-setup.exe"
    url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{name}"
    installer = None
    assets = data.get("assets", [])
    if isinstance(assets, list):
        for asset in assets:
            if not isinstance(asset, dict) or asset.get("name") != name:
                continue
            digest = asset.get("digest")
            size = asset.get("size")
            if (asset.get("state") == "uploaded"
                    and asset.get("browser_download_url") == url
                    and type(size) is int and 0 < size <= 1024 ** 3
                    and isinstance(digest, str)
                    and re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest)):
                installer = ReleaseAsset(url, size, digest[7:].lower())
                break
    return ReleaseInfo(tag, data.get("body") or "", installer)

"""Release version parsing shared by packaging scripts and CI checks."""

import re

STABLE_VERSION = re.compile(r"^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$")
BETA_VERSION = re.compile(
    r"^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)-beta\.(?:0|[1-9]\d*)$",
)
RELEASE_TAG = re.compile(
    r"^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-beta\.(?:0|[1-9]\d*))?$",
)


def parse_release_version(version: str) -> tuple[str, str]:
    """Return (version, channel) for stable or beta release versions."""
    if STABLE_VERSION.fullmatch(version):
        return version, "stable"
    if BETA_VERSION.fullmatch(version):
        return version, "beta"
    raise ValueError(
        "版本号必须为 MAJOR.MINOR.PATCH 或 MAJOR.MINOR.PATCH-beta.N，例如 0.15.1 或 0.15.4-beta.1。"
    )


def is_prerelease_version(version: str) -> bool:
    return BETA_VERSION.fullmatch(version) is not None


def version_sort_key(version: str) -> tuple[int, ...]:
    """Order stable releases after betas of the same X.Y.Z."""
    if STABLE_VERSION.fullmatch(version):
        return (*tuple(map(int, version.split("."))), 1, 0)
    match = BETA_VERSION.fullmatch(version)
    if match is None:
        raise ValueError(f"unsupported release version: {version}")
    base, beta = version.split("-beta.", 1)
    return (*tuple(map(int, base.split("."))), 0, int(beta))


def tag_for_version(version: str) -> str:
    return f"v{version}"


def version_from_tag(tag: str) -> str:
    if not RELEASE_TAG.fullmatch(tag):
        raise ValueError(f"unsupported release tag: {tag}")
    return tag.removeprefix("v")

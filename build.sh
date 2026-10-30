#!/usr/bin/env bash
# Build native Flutter and the separate CLI/MCP tools on this host.
set -euo pipefail
cd "$(dirname "$0")"
PY=.venv/bin/python
if [ ! -x "$PY" ]; then
    echo 'error: create .venv first: python3 -m venv .venv' >&2
    exit 1
fi
"$PY" -m pip install -e ".[build]" -e ./mcp
"$PY" packaging/build.py

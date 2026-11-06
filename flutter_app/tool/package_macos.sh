#!/bin/bash
# Produce a local update asset; publishing is deliberately a separate action.
set -euo pipefail
cd "$(dirname "$0")/.."
bash tool/build_macos.sh "$@"
app="$PWD/build/macos/Build/Products/Release/Modbus Connector.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'A stable semantic version is required for a macOS update asset.' >&2
  exit 1
fi
staging=$(mktemp -d "${TMPDIR:-/tmp}/modbus-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$app" "$staging/Modbus Connector.app"
asset="$PWD/build/macos/modbus-connector-flutter-$version-macos-universal.dmg"
if [ -e "$asset" ]; then
  echo "Asset already exists: $asset" >&2
  exit 1
fi
/usr/bin/hdiutil create -format UDZO -volname 'Modbus Connector' -srcfolder "$staging" "$asset"
/usr/bin/shasum -a 256 "$asset" > "$asset.sha256"
echo "Created $asset"

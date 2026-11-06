#!/bin/bash
# Build and verify a local universal application. Does not publish or install it.
set -euo pipefail
cd "$(dirname "$0")/.."
flutter_bin="${FLUTTER_BIN:-flutter}"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo 'Full Xcode is required. Select its developer directory before building.' >&2
  exit 1
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo 'Xcode first-launch setup is incomplete. Open Xcode, review its license and finish installing required components.' >&2
  exit 1
fi
for tool in pod autoconf automake glibtoolize; do
  if ! command -v "$tool" >/dev/null; then
    echo "Missing $tool: CocoaPods and GNU autotools are required by the serial-port plugin." >&2
    exit 1
  fi
done
"$flutter_bin" pub get
version=$(sed -n 's/^__version__ = "\([0-9.]*\)"$/\1/p' ../src/modbus_connector/__init__.py)
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Invalid release version in src/modbus_connector/__init__.py' >&2
  exit 1
fi
"$flutter_bin" build macos --release "$@" --build-name="$version" --dart-define="APP_VERSION=$version"
app='build/macos/Build/Products/Release/Modbus Connector.app'
test -d "$app"
count=0
while IFS= read -r -d '' binary; do
  if /usr/bin/file -b "$binary" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/lipo "$binary" -verify_arch arm64 x86_64
    count=$((count + 1))
  fi
done < <(/usr/bin/find "$app" -type f -print0)
test "$count" -gt 0
/usr/bin/codesign --verify --deep --strict "$app"
echo "Verified $count universal Mach-O files in $app"

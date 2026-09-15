#!/bin/bash
# Build the app, install it on a connected iPhone, and launch it.
# Usage: ./deploy.sh [udid]   (defaults to the first available iPhone)
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -ge 1 ]; then
  udid="$1"
else
  udid=$(xcrun devicectl list devices \
    | awk '/iPhone/ && /available/ { print $3; exit }')
fi

if [ -z "$udid" ]; then
  echo "no connected iPhone found — plug one in and unlock it" >&2
  exit 1
fi

echo "==> building for $udid"
xcodebuild -project Chessfen.xcodeproj -scheme Chessfen -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/dd build

echo "==> installing"
xcrun devicectl device install app --device "$udid" \
  /tmp/dd/Build/Products/Release-iphoneos/Chessfen.app

echo "==> launching"
xcrun devicectl device process launch --device "$udid" \
  --terminate-existing com.sunfmin.chessfen

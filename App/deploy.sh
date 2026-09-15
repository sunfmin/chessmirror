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

# Every deploy is stamped, so "is the build with that fix actually on the phone" — the first
# question worth asking about a report from a device — has an answer. Passed as a setting rather
# than written into project.yml: it is a fact about this build, not about the app, and a file
# that changes on every deploy is a file that conflicts on every deploy.
stamp=$(date +%Y%m%d%H%M)

echo "==> building for $udid (build $stamp)"
xcodebuild -project Chessfen.xcodeproj -scheme Chessfen -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/dd \
  CURRENT_PROJECT_VERSION="$stamp" build

echo "==> installing"
xcrun devicectl device install app --device "$udid" \
  /tmp/dd/Build/Products/Release-iphoneos/Chessfen.app

echo "==> launching"
xcrun devicectl device process launch --device "$udid" \
  --terminate-existing com.sunfmin.chessfen

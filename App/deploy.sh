#!/bin/bash
# Build the app, install it on a connected iPhone, and launch it.
# Usage: ./deploy.sh [udid]   (defaults to the first available iPhone)
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -ge 1 ]; then
  udid="$1"
else
  # The identifier is picked out by its shape rather than its column: Xcode 27 prints it as
  # `00008150-000144891A42401C (UDID)` with an empty Hostname column before it, so the third
  # column is the literal "(UDID)" and the build would try to install onto that.
  udid=$(xcrun devicectl list devices \
    | awk '/iPhone/ && /available/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-Fa-f-]{20,}$/) { print $i; exit } }')
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
# Built for this device rather than any iOS device, and allowed to touch provisioning: a phone or
# iPad the account has not seen before is registered and written into the profile here. Built
# generically, the profile was whatever it last was, and a new device refused the install with
# "This provisioning profile cannot be installed on this device".
xcodebuild -project Chessmirror.xcodeproj -scheme Chessmirror -configuration Release \
  -destination "id=$udid" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -derivedDataPath /tmp/dd \
  CURRENT_PROJECT_VERSION="$stamp" build

echo "==> installing"
xcrun devicectl device install app --device "$udid" \
  /tmp/dd/Build/Products/Release-iphoneos/Chessmirror.app

echo "==> launching"
xcrun devicectl device process launch --device "$udid" \
  --terminate-existing com.sunfmin.chessmirror

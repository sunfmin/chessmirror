#!/bin/bash
# Build the app for the App Store and send it to App Store Connect, where it turns up under
# TestFlight once Apple has processed it. What happens around the upload — the store record, its
# words and pictures, submitting for review — is fastlane/Fastfile and docs/appstore.md.
# Usage: ./appstore.sh [--no-upload]
#   --no-upload  build, sign and have Apple validate the package, without sending it.
set -euo pipefail
cd "$(dirname "$0")"

upload=1
for arg in "$@"; do
  case "$arg" in
    --no-upload) upload=0 ;;
    *) echo "usage: $0 [--no-upload]" >&2; exit 2 ;;
  esac
done

# Signing and the upload both sign in with the App Store Connect API key in mytokens. Xcode and
# altool only take it as a file, so it is one for as long as this script runs.
key_id=$(mytokens get asc-api-key --field "Key ID")
issuer=$(mytokens get asc-api-key --field "Issuer ID")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(umask 077; mytokens get asc-api-key --field "Key (base64 .p8)" | base64 -d > "$work/AuthKey_$key_id.p8")
export API_PRIVATE_KEYS_DIR="$work"
sign_in=(-allowProvisioningUpdates -authenticationKeyPath "$work/AuthKey_$key_id.p8"
  -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")

# The same stamp deploy.sh puts on a phone build, and for the same reason: 关于 shows it, and the
# store refuses a build number it has already seen under this version.
stamp=$(date +%Y%m%d%H%M)
archive=/tmp/dd-appstore/Chessmirror.xcarchive
ipa=/tmp/dd-appstore/export/Chessmirror.ipa

xcodegen generate --quiet

echo "==> archiving (build $stamp)"
xcodebuild -project Chessmirror.xcodeproj -scheme Chessmirror -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath /tmp/dd-appstore -archivePath "$archive" \
  "${sign_in[@]}" CURRENT_PROJECT_VERSION="$stamp" archive

echo "==> exporting for the store"
cat > "$work/export.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
rm -rf "$(dirname "$ipa")"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$(dirname "$ipa")" \
  -exportOptionsPlist "$work/export.plist" "${sign_in[@]}"

echo "==> validating"
xcrun altool --validate-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"
if [ "$upload" = 0 ]; then
  echo "validated, not uploaded (--no-upload): $ipa (build $stamp)"
  exit 0
fi

echo "==> uploading build $stamp"
xcrun altool --upload-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"
echo "uploaded build $stamp"

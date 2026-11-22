#!/bin/bash
# The App Store release, in three steps that each sign in with the App Store Connect API key and
# nothing else: no signing identity in the keychain, no web session. docs/appstore.md has the
# order and what each step needs.
#
#   ./appstore.sh build [--no-upload]   archive, have Xcode sign it in the cloud, validate, upload
#   ./appstore.sh page                  words, release notes, pictures, age rating, categories
#   ./appstore.sh submit <build>        attach that build to the version and put it up for review
#
# build --no-upload: build, sign and have Apple validate the package, without sending it.
# page --dry-run, submit <build> --dry-run: read the store and say what would change, writing
# nothing (asc refuses every write under ASC_READ_ONLY).
# The store calls go through asc (https://asccli.sh); the key is read from the environment, so
# there is no asc profile or config to keep.
set -euo pipefail
cd "$(dirname "$0")"

APP_ID=6820324541
TEAM_ID=HL27PWAKDF
usage() { echo "usage: $0 build [--no-upload] | page [--dry-run] | submit <build number> [--dry-run]" >&2; exit 2; }
[ $# -ge 1 ] || usage
step=$1; shift
dry=0
args=()
for arg in "$@"; do
  case "$arg" in --dry-run) dry=1 ;; *) args+=("$arg") ;; esac
done
if [ "$dry" = 1 ]; then
  [ "$step" != build ] || usage
  export ASC_READ_ONLY=1
fi
# asc's flag for the same choice: say what would happen, or do it.
if [ "$dry" = 1 ]; then commit=--dry-run; else commit=--confirm; fi

# The key lives in mytokens only. Xcode, altool and asc all take it as a file, so it is one for as
# long as this script runs.
key_id=$(mytokens get asc-api-key --field "Key ID")
issuer=$(mytokens get asc-api-key --field "Issuer ID")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
key="$work/AuthKey_$key_id.p8"
(umask 077; mytokens get asc-api-key --field "Key (base64 .p8)" | base64 -d > "$key")
export API_PRIVATE_KEYS_DIR="$work"
export ASC_BYPASS_KEYCHAIN=1 ASC_KEY_ID="$key_id" ASC_ISSUER_ID="$issuer" ASC_PRIVATE_KEY_PATH="$key"

# The version the store record is for: the one the app says it is.
version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | sort -u)
[ "$(printf '%s\n' "$version" | wc -l)" -eq 1 ] || { echo "the targets in project.yml disagree on MARKETING_VERSION" >&2; exit 1; }

build() {
  local upload=1
  for arg in "$@"; do
    case "$arg" in --no-upload) upload=0 ;; *) usage ;; esac
  done
  # The same stamp deploy.sh puts on a phone build, and for the same reason: 关于 shows it, and the
  # store refuses a build number it has already seen under this version.
  local stamp archive ipa
  stamp=$(date +%Y%m%d%H%M)
  archive=/tmp/dd-appstore/Chessmirror.xcarchive
  ipa=/tmp/dd-appstore/export/Chessmirror.ipa

  xcodegen generate --quiet

  # Unsigned: the archive needs no identity here. The export below signs it with Apple Distribution
  # certificates Apple keeps for the team (cloud-managed), which the key may use; a local identity,
  # or the development certificate whose private key lives on one Mac only, is never asked for.
  echo "==> archiving (build $stamp)"
  xcodebuild -project Chessmirror.xcodeproj -scheme Chessmirror -configuration Release \
    -destination "generic/platform=iOS" -derivedDataPath /tmp/dd-appstore -archivePath "$archive" \
    CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$stamp" archive

  # What the store hands to an A12 iPad too: its armv8 engine must hold no dotprod (docs/adr/0052).
  ../scripts/dotprod-confined.sh "$archive/Products/Applications/Chessmirror.app/Chessmirror"

  echo "==> exporting for the store, signed in the cloud"
  cat > "$work/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
  rm -rf "$(dirname "$ipa")"
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$(dirname "$ipa")" \
    -exportOptionsPlist "$work/export.plist" -allowProvisioningUpdates \
    -authenticationKeyPath "$key" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer"

  echo "==> validating"
  xcrun altool --validate-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"
  if [ "$upload" = 0 ]; then
    echo "validated, not uploaded (--no-upload): $ipa (build $stamp)"
    return
  fi
  echo "==> uploading build $stamp"
  xcrun altool --upload-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"
  echo "uploaded build $stamp"
}

# The version's id, making the version first if the store has none by that number yet. Once
# approved it goes on sale by itself.
version_id() {
  local id
  id=$(asc versions list --app "$APP_ID" --platform IOS --version "$version" --output json | jq -r '.data[0].id // empty')
  if [ -z "$id" ]; then
    [ "$dry" = 0 ] || { echo "the store has no version $version yet; page would make it, and there is nothing to compare against" >&2; exit 1; }
    echo "==> making version $version" >&2
    id=$(asc versions create --app "$APP_ID" --platform IOS --version "$version" \
      --release-type AFTER_APPROVAL --output json | jq -r '.data.id')
  fi
  echo "$id"
}

page() {
  [ $# -eq 0 ] || usage
  local fastlane=../fastlane shots stage vid
  shots=(out/store-*.png)
  [ -e "${shots[0]}" ] || { echo "no pictures in App/out: run StoreScreenshotTests on both simulators first (docs/appstore.md)" >&2; exit 1; }
  vid=$(version_id)

  # The words are fastlane/metadata, in deliver's layout, which asc reads as it is. The reviewer's
  # contact is the `chessmirror` profile's when it is loaded (a phone number being no thing to
  # commit); without it the version keeps the contact it has.
  stage="$work/fastlane"
  mkdir -p "$stage/screenshots"
  cp -R "$fastlane/metadata" "$stage/metadata"
  if [ -n "${APP_REVIEW_EMAIL:-}" ]; then
    local r="$stage/metadata/review_information"
    printf '%s' "$APP_REVIEW_FIRST_NAME" > "$r/first_name.txt"
    printf '%s' "$APP_REVIEW_LAST_NAME" > "$r/last_name.txt"
    printf '%s' "$APP_REVIEW_PHONE" > "$r/phone_number.txt"
    printf '%s' "$APP_REVIEW_EMAIL" > "$r/email_address.txt"
  fi
  # A dry run shows what each step would send; a real one keeps quiet unless it fails.
  show() { if [ "$dry" = 1 ]; then jq "$1"; else cat >/dev/null; fi; }

  echo "==> words, release notes, copyright, notes for the reviewer"
  local check=()
  [ "$dry" = 0 ] || check=(--check-remote)
  asc migrate import --app "$APP_ID" --version-id "$vid" --fastlane-dir "$stage" --skip-screenshots \
    "$commit" ${check[@]+"${check[@]}"} --output json \
    | show '{copyright, reviewInformation: (.reviewInformation // {} | keys),
             version: [.localizations[] | {locale, fields: (keys - ["locale"])}],
             appInfo: [.appInfoLocalizations[] | {locale, fields: (keys - ["locale"])}]}'

  # The pictures are store-<language>-<iphone|ipad>-<n>-<what>.png; asc wants a folder per language
  # and picks each device's files by their size. --replace empties the set first, so this can be
  # run again. The iPhone set is the 6.7" one the store has had since 1.0. The test draws them with
  # an alpha channel, which asc refuses; as a full-quality JPEG they have none.
  local shot language
  for shot in "${shots[@]}"; do
    language=$(basename "$shot" | sed -nE 's/^store-(.+)-(iphone|ipad)-.*/\1/p')
    [ -n "$language" ] || { echo "not a store picture's name: $shot" >&2; exit 1; }
    mkdir -p "$stage/screenshots/$language"
    sips -s format jpeg -s formatOptions 100 "$shot" \
      --out "$stage/screenshots/$language/$(basename "$shot" .png).jpg" >/dev/null
  done
  for device in IPHONE_67 IPAD_PRO_3GEN_129; do
    echo "==> pictures: $device"
    asc screenshots upload --app "$APP_ID" --version-id "$vid" --path "$stage/screenshots" \
      --device-type "$device" --replace "$commit" --output json \
      | show '[.localizations[] | {locale, set: .setId, files: ([.results[].state] | group_by(.) | map({(.[0]): length}) | add)}]'
  done

  # The age rating is the editable appInfo's ageRatingDeclaration, not the version's. Its keys go
  # as they are in fastlane/age-rating.json (docs/appstore.md says why each is there).
  echo "==> age rating"
  local info rating
  info=$(asc api GET "/v1/apps/$APP_ID/appInfos" | jq -r '[.data[] | select(.attributes.state != "READY_FOR_DISTRIBUTION")][0].id')
  asc api GET "/v1/appInfos/$info/ageRatingDeclaration" > "$work/rating.json"
  rating=$(jq -r '.data.id' "$work/rating.json")
  if [ "$dry" = 1 ]; then
    jq --slurpfile want "$fastlane/age-rating.json" \
      '.data.attributes as $have | {ageRatingDeclaration: .data.id,
       changes: [$want[0] | to_entries[] | select($have[.key] != .value) | {key, from: $have[.key], to: .value}]}' "$work/rating.json"
  else
    jq --arg id "$rating" '{data: {type: "ageRatingDeclarations", id: $id, attributes: .}}' \
      "$fastlane/age-rating.json" > "$work/age-rating.json"
    asc api PATCH "/v1/ageRatingDeclarations/$rating" --body-file "$work/age-rating.json" --confirm >/dev/null
  fi

  echo "==> categories"
  local m="$fastlane/metadata"
  mkdir "$work/categories"
  jq -n --arg p "$(cat "$m/primary_category.txt")" --arg p1 "$(cat "$m/primary_first_sub_category.txt")" \
    --arg p2 "$(cat "$m/primary_second_sub_category.txt")" --arg s "$(cat "$m/secondary_category.txt")" \
    '{primaryCategory: $p, primarySubcategoryOne: $p1, primarySubcategoryTwo: $p2, secondaryCategory: $s}' \
    > "$work/categories/categories.json"
  asc metadata apply --app "$APP_ID" --app-info "$info" --version "$version" --dir "$work/categories" \
    --include categories "$commit" --output json | show '{adds, updates, deletes}'

  if [ "$dry" = 1 ]; then echo "dry run: nothing sent for $version"; else echo "page sent for $version"; fi
}

submit() {
  [ $# -eq 1 ] || usage
  local vid
  vid=$(version_id)
  # Waits for Apple to finish processing the build, attaches it, and submits the version as the
  # page step last left it.
  asc review submit --app "$APP_ID" --version-id "$vid" --build-number "$1" --wait "$commit"
  [ "$dry" = 1 ] || echo "build $1 of $version is up for review"
}

case "$step" in
  build) build ${args[@]+"${args[@]}"} ;;
  page) page ${args[@]+"${args[@]}"} ;;
  submit) submit ${args[@]+"${args[@]}"} ;;
  *) usage ;;
esac

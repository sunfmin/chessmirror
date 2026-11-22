# Releasing to the App Store

The app's store record is **Chessmirror – Chess Trainer** (中文区「棋镜 – 国际象棋训练」), Apple ID
`6820324541`, bundle `com.sunfmin.chessmirror`, SKU `chessmirror`. "Chessmirror" by itself was
taken by another account. Free, every territory, English the primary language.

## A release, in order

Every step signs in with the App Store Connect API key, `asc-api-key` in mytokens, and nothing
else, so it runs on any Mac that has that secret (see "Signing in").

```bash
# 1. The build. Prints the build number it stamped; about a minute and a half to build, a few
#    more to upload. Apple then processes it for a few minutes.
cd App && ./appstore.sh build               # --no-upload: build, sign and validate only

# 2. The pictures, once per screen size the store asks for. They land in App/out/store-*.png.
for device in "iPhone 17 Pro Max" "iPad Pro 13-inch (M5)"; do
  xcodebuild test -project Chessmirror.xcodeproj -scheme Chessmirror \
    -destination "platform=iOS Simulator,name=$device" ARCHS=arm64 \
    -only-testing:ScreenTests/StoreScreenshotTests
done

# 3. The page: words, release notes, pictures, age rating, categories, notes for the reviewer.
#    Makes the version (released once approved) if the store has none by this number yet.
#    The `chessmirror` profile adds the reviewer's contact; without it the version keeps the one
#    it has. --dry-run reads the store and prints what would change.
(eval "$(mytokens env chessmirror)"; ./appstore.sh page)

# 4. Into review: waits until Apple has processed the build, attaches it, submits.
#    Once approved it goes on sale by itself. --dry-run here too.
./appstore.sh submit <number from step 1>
```

For a new version, raise `MARKETING_VERSION` in `App/project.yml` (both targets) first and add
`fastlane/metadata/<language>/release_notes.txt`. `appstore.sh` takes the version from there.

The App Privacy answers are not in these steps: the API has no call for them, so they need the
web session (`fastlane privacy`, below). They stay on the record from one version to the next;
run it only when `fastlane/app-privacy.json` changes.

`asc validate --app 6820324541 --version <version>` is a readiness check worth reading before
step 4, but it also reports `socialMediaAgeRestricted` as missing, which Apple does not ask of an
app without social media (below).

## Where each thing is kept

| What | Where |
| --- | --- |
| Name, subtitle, keywords, description, the two URLs, categories, copyright | `fastlane/metadata/` — deliver's layout, which `asc migrate import` reads as it is; edit them there |
| Pictures | `App/ScreenTests/StoreScreenshotTests.swift` draws them |
| Age rating (everything "none": 4+) | `fastlane/age-rating.json` — `appstore.sh page` sends its keys to the editable appInfo's ageRatingDeclaration as they are, so a question Apple adds needs a key here (see below) |
| App privacy ("Data Not Collected") | `fastlane/app-privacy.json`; the reasons are `docs/privacy.md`, which is also the privacy policy the store links to |
| Notes for the reviewer | `fastlane/metadata/review_information/notes.txt` |
| Reviewer's contact | the `chessmirror` profile in mytokens (`APP_REVIEW_*`) |
| Export compliance | `ITSAppUsesNonExemptEncryption: false` in `App/project.yml` |

### The age rating's newer questions

JSON takes no comments, and any key in the file goes to the API, so the reasons live here.
Apple asked these after 1.0; submitting 1.1 stopped on `socialMedia` having no value
(`ENTITY_ERROR.ATTRIBUTE.REQUIRED`, 2026-11-22). All are booleans in the App Store Connect API's
ageRatingDeclaration, and each is `false`, which keeps the rating at 4+:

- `socialMedia`: no social media features. Nothing is posted, followed or shared with others.
- `datingAndRelationships`: the app connects no one with anyone.
- `sharedLocation`: the app never reads the location, let alone shares it.

Left out on purpose: `socialMediaAgeRestricted` (asked only of an app with social media), and
`kidsAgeBand`, `gracRatingClassificationNumber`, `developerAgeRatingInfoUrl`,
`ageRatingOverride*`, `koreaAgeRatingOverride`, which are not questions but settings for apps in
the Kids category, a Korean rating, or an override; this app uses none.

## Signing in

| Step | Needs |
| --- | --- |
| `appstore.sh build` | `asc-api-key` |
| `appstore.sh page` | `asc-api-key`; the `chessmirror` profile only to set the reviewer's contact |
| `appstore.sh submit` | `asc-api-key` |
| `fastlane privacy` | the `calcgrid` profile's web session |

- **The key** (`asc-api-key`: Key ID, Issuer ID, the .p8 in base64) is all the build and the store
  calls use. `appstore.sh` writes it to a temporary file for Xcode, altool and
  [asc](https://asccli.sh) (`brew install asc`), which reads it from the environment
  (`ASC_BYPASS_KEYCHAIN`, `ASC_KEY_ID`, …): there is no asc profile or `~/.asc` config to keep.
- **Signing needs no identity on the Mac.** The archive is built unsigned
  (`CODE_SIGNING_ALLOWED=NO`), and the export signs it with automatic signing, team `HL27PWAKDF`,
  through the key: Apple signs with cloud-managed "Apple Distribution" certificates and makes the
  profiles. The keychain is never asked, so a Mac with no code-signing identity (macnomac-studio)
  builds the release, and the personal Mac's development certificate is never revoked to make one.
- **`fastlane privacy`** signs in as the developer account, with the `fastlane spaceauth` session
  kept in the `calcgrid` profile (`FASTLANE_USER`, `FASTLANE_SESSION`). It lasts about a month;
  when it has lapsed, run `fastlane spaceauth -u <Apple ID>` in a terminal of your own and store
  the new one with `mytokens put calcgrid --fields "FASTLANE_SESSION"`.

## Done once, by hand (2026-10-08)

Not in the lanes, because they are not done again:

- The store record: `fastlane produce create -a com.sunfmin.chessmirror --app_name "Chessmirror – Chess Trainer" --language en-US --sku chessmirror --skip_devcenter`.
- Price (free) and availability (all 175 territories, and new ones as they appear), and the
  content rights declaration (no third-party content) — three calls to the App Store Connect
  API. deliver's `price_tier` still speaks to an interface Apple has removed.
- The repository made public: the store's support and privacy links point into it, and a
  GPLv3 binary owes its users the source.

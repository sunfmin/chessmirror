# Releasing to the App Store

The app's store record is **Chessmirror – Chess Trainer** (中文区「棋镜 – 国际象棋训练」), Apple ID
`6820324541`, bundle `com.sunfmin.chessmirror`, SKU `chessmirror`. "Chessmirror" by itself was
taken by another account. Free, every territory, English the primary language.

## A release, in order

```bash
# 1. The build. Prints the build number it stamped; about a minute and a half to build, a few
#    more to upload. Apple then processes it for a few minutes.
cd App && ./appstore.sh                     # --no-upload: build, sign and validate only

# 2. The pictures, once per screen size the store asks for. They land in App/out/store-*.png.
for device in "iPhone 17 Pro Max" "iPad Pro 13-inch (M5)"; do
  xcodebuild test -project Chessmirror.xcodeproj -scheme Chessmirror \
    -destination "platform=iOS Simulator,name=$device" ARCHS=arm64 \
    -only-testing:ScreenTests/StoreScreenshotTests
done

# 3. The page: words, pictures, age rating, privacy answers, reviewer's contact.
cd .. && (eval "$(mytokens env calcgrid)"; eval "$(mytokens env chessmirror)"; fastlane store_page)

# 4. Into review. Once approved it goes on sale by itself.
(eval "$(mytokens env calcgrid)"; fastlane submit build:<number from step 1>)
```

For a new version, raise `MARKETING_VERSION` in `App/project.yml` (both targets) first and add
`fastlane/metadata/<language>/release_notes.txt`.

## Where each thing is kept

| What | Where |
| --- | --- |
| Name, subtitle, keywords, description, the two URLs, categories, copyright | `fastlane/metadata/` — the files deliver reads; edit them there |
| Pictures | `App/ScreenTests/StoreScreenshotTests.swift` draws them |
| Age rating (everything "none": 4+) | `fastlane/age-rating.json` |
| App privacy ("Data Not Collected") | `fastlane/app-privacy.json`; the reasons are `docs/privacy.md`, which is also the privacy policy the store links to |
| Notes for the reviewer | `fastlane/review-notes.txt` |
| Reviewer's contact | the `chessmirror` profile in mytokens (`APP_REVIEW_*`) |
| Export compliance | `ITSAppUsesNonExemptEncryption: false` in `App/project.yml` |

## Signing in

- **The build** signs and uploads with the App Store Connect API key, `asc-api-key` in mytokens.
  Signing is automatic: Xcode makes the distribution profiles itself.
- **fastlane** signs in as the developer account, with the `fastlane spaceauth` session kept in
  the `calcgrid` profile (`FASTLANE_USER`, `FASTLANE_SESSION`). It lasts about a month; when it
  has lapsed, run `fastlane spaceauth -u <Apple ID>` in a terminal of your own and store the new
  one with `mytokens put calcgrid --fields "FASTLANE_SESSION"`.

## Done once, by hand (2026-10-08)

Not in the lanes, because they are not done again:

- The store record: `fastlane produce create -a com.sunfmin.chessmirror --app_name "Chessmirror – Chess Trainer" --language en-US --sku chessmirror --skip_devcenter`.
- Price (free) and availability (all 175 territories, and new ones as they appear), and the
  content rights declaration (no third-party content) — three calls to the App Store Connect
  API. deliver's `price_tier` still speaks to an interface Apple has removed.
- The repository made public: the store's support and privacy links point into it, and a
  GPLv3 binary owes its users the source.

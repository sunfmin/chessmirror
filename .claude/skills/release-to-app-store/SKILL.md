---
name: release-to-app-store
description: Use to put a new build or version of Chessmirror on the App Store: the build, the store pictures, the page, the submission, and where each thing the store shows is kept.
---

# Releasing to the App Store

Every step signs in with the App Store Connect API key, `asc-api-key` in optokens, and nothing
else (ADR 0055), so it runs on any Mac that has that secret. `App/appstore.sh` holds the store
record's ids and says what each step does.

## A release, in order

```bash
# 1. The build. Prints the build number it stamped. Apple then processes it for a while.
cd App && ./appstore.sh build               # --no-upload: build, sign and validate only

# 2. The pictures, once per screen size the store asks for. They land in App/out/store-*.png.
for device in "iPhone 17 Pro Max" "iPad Pro 13-inch (M5)"; do
  xcodebuild test -project Chessmirror.xcodeproj -scheme Chessmirror \
    -destination "platform=iOS Simulator,name=$device" ARCHS=arm64 \
    -only-testing:ScreenTests/StoreScreenshotTests
done

# 3. The page. Makes the version if the store has none by this number yet. The `chessmirror`
#    profile adds the reviewer's contact; without it the version keeps the one it has.
(eval "$(optokens env chessmirror)"; ./appstore.sh page)    # --dry-run: print what would change

# 4. Into review: waits until Apple has processed the build, attaches it, submits.
#    Once approved it goes on sale by itself. --dry-run here too.
./appstore.sh submit <number from step 1>
```

For a new version, raise `MARKETING_VERSION` in `App/project.yml` (both targets) first and add
`fastlane/metadata/<language>/release_notes.txt`.

The App Privacy answers are not in these steps: they stay on the record from one version to the
next. Run `(eval "$(optokens env calcgrid)"; fastlane privacy)` only when
`fastlane/app-privacy.json` changes.

`asc validate --app 6820324541 --version <version>` is worth reading before step 4, but it also
reports `socialMediaAgeRestricted` as missing, which Apple does not ask of this app (ADR 0056).

## Where each thing is kept

| What | Where |
| --- | --- |
| Name, subtitle, keywords, description, the two URLs, categories, copyright | `fastlane/metadata/`, deliver's layout, which `asc migrate import` reads as it is |
| Pictures | `App/ScreenTests/StoreScreenshotTests.swift` draws them |
| Age rating | `fastlane/age-rating.json`; why each answer, and what to do when Apple adds a question, is ADR 0056 |
| App privacy | `fastlane/app-privacy.json`; the reasons are `docs/privacy.md`, the policy the store links to |
| Notes for the reviewer | `fastlane/metadata/review_information/notes.txt` |
| Reviewer's contact | the `chessmirror` profile in optokens (`APP_REVIEW_*`) |
| Export compliance | `ITSAppUsesNonExemptEncryption: false` in `App/project.yml` |
| Price, availability, content rights | on the store record only, set once by API calls; deliver's `price_tier` speaks to an interface Apple has removed |

## When `fastlane privacy` cannot sign in

Its `fastlane spaceauth` session, kept in the `calcgrid` profile, lapses about monthly. The
person runs `fastlane spaceauth -u <Apple ID>` in a terminal of their own. You run
`optokens put calcgrid --fields "FASTLANE_SESSION"`: it prints a one-time link on stderr (on the
tailnet, good for one submission until it expires) and waits. Hand that link to the person,
who pastes the session there. Never ask for the session in a popup or a terminal, and never print it.

optokens answers `get` and `env` from a local copy for a few minutes, so after a Secret
is changed on another host, give `--fresh` to the next `optokens get` or `optokens env`.

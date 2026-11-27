# The release signs in with the App Store Connect API key alone

Building, signing, uploading, writing the store page and submitting all sign in with one App
Store Connect API key, kept in optokens as `asc-api-key` (Key ID, Issuer ID, the .p8 in base64),
so any Mac that has that secret can release.

- **No signing identity on the Mac.** The archive is built unsigned (`CODE_SIGNING_ALLOWED=NO`)
  and the export signs it with automatic signing, team `HL27PWAKDF`, through the key: Apple signs
  with cloud-managed "Apple Distribution" certificates and makes the profiles. The keychain is
  never asked, so a Mac with no code-signing identity (macnomac-studio) builds the release, and
  the personal Mac's development certificate, whose private key lives on that Mac only, is never
  revoked to make one.
- **No tool configuration to keep.** `App/appstore.sh` writes the key to a temporary file for
  Xcode, altool and [asc](https://asccli.sh) for as long as it runs; asc reads it from the
  environment (`ASC_BYPASS_KEYCHAIN`, `ASC_KEY_ID`, …), so there is no asc profile or `~/.asc`.

## The one exception

The App Privacy answers have no call in the API, so `fastlane privacy` (`fastlane/Fastfile`)
signs in as the developer account with a `fastlane spaceauth` session, kept in the `calcgrid`
profile (`FASTLANE_USER`, `FASTLANE_SESSION`), the developer account's rather than this app's.
The answers stay on the record from one version to the next, so it runs only when they change.

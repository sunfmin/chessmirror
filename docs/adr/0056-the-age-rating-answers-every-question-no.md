# The age rating answers every question no

Every question in `fastlane/age-rating.json` is answered "none" or `false`, which keeps the app
at 4+. The reasons live here because JSON takes no comments and `appstore.sh page` sends every
key of the file to the editable appInfo's ageRatingDeclaration as it is.

## The questions Apple added after 1.0

Submitting 1.1 stopped on `socialMedia` having no value (`ENTITY_ERROR.ATTRIBUTE.REQUIRED`,
2026-11-22): a question Apple adds needs a key in the file before the next submission. These
are booleans in the API, each `false`:

- `socialMedia`: no social media features. Nothing is posted, followed or shared with others.
- `datingAndRelationships`: the app connects no one with anyone.
- `sharedLocation`: the app never reads the location, let alone shares it.

## Left out on purpose

`socialMediaAgeRestricted` is asked only of an app with social media, though `asc validate`
reports it missing. `kidsAgeBand`, `gracRatingClassificationNumber`,
`developerAgeRatingInfoUrl`, `ageRatingOverride*` and `koreaAgeRatingOverride` are not
questions but settings for apps in the Kids category, a Korean rating, or an override; this app
uses none.

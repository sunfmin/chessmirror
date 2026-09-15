# The app speaks eight languages, from tables in the package

Chinese, English, French, Japanese, Korean, German, Spanish, Portuguese. Chinese is the
language the app was written in and the one every other falls back to, key by key: a
sentence that has not been translated yet comes out in Chinese rather than as a key, and
a screen is never half in symbols.

## The words live with the domain, not with the screens

`Localizable.strings` sits in `ChessfenKit`, eight `Resources/<lang>.lproj` folders of
it, and not in the app target. The reason is that most of what has to be translated is
not screen furniture — it is the vocabulary of the domain itself. 漏着, 说不清, "e4 is not
a square a bishop can reach", "王旁边有王" — these are `MoveQuality`, `Intent`, `FENIssue`
values, and a `FENIssue` that could not say what it was in the reader's language would
push that job onto every screen that shows one. So each domain type owns its `.label`
(`Vocabulary.swift`), the kit's tests can assert against it, and the app target holds
only the eight `InfoPlist.strings` iOS reads before the app has run: the name under the
icon and the two permission sentences.

## A `.strings` folder, not a String Catalog

`.xcstrings` is what Xcode offers now, and `swift build` **copies it into the bundle
without compiling it** — verified rather than assumed, by putting one in and watching a
lookup come back as its own key. A package whose tests run under `swift test` and whose
code also builds into an app needs a form both toolchains understand, and that is still
`<lang>.lproj/Localizable.strings`. One wrinkle worth knowing: SwiftPM lowercases the
folder to `zh-hans.lproj` where Xcode leaves it alone, so the lookup tries both spellings.

## The language is `Speech.language`, not the system's

Lookup goes through `localized(_:)` against a bundle picked by `Speech.language`, not
through `String(localized:)`. Three things need that:

- **The person can choose.** A phone in English held by somebody who reads chess in
  Chinese is the ordinary case here, not the exotic one. Settings offers 跟随系统 plus the
  eight, each written in its own language, and the choice travels in the iCloud key-value
  store like every other setting.
- **Tests can scope one.** `Speech.speaking(.chinese) { … }` is a task-local, so suites
  running side by side do not take the language out from under each other, and a screen
  test asserting a Chinese sentence passes on an English simulator. The one place it has
  to be handed over by hand is `Task.detached`, which starts outside every task-local.
- **The fallback is ours.** Key present but empty, language missing a key entirely: both
  fall through to Chinese, in our code, where a test can see it happen.

## Two plural forms, chosen by a `Language`

`"habits.times"` and `"habits.times.one"` — one extra key, used when the count is
singular for that language. No `.stringsdict`, because for exactly these eight the rule
is small enough to write down and read: Chinese, Japanese and Korean have one form;
English, German, Spanish and Portuguese take the singular at 1; French takes it at 0 and
1. A ninth language with a real plural system (Russian, Polish, Arabic) is the trigger to
switch, and until then a `.stringsdict` per language would be forty lines of XML each to
express what `Language.isSingular(_:)` says in four.

## Drift is a test failure

`LocalizationTests` reads all eight tables and fails if any key is missing from one, or
extra in one, or blank, or carries a different set of `%@`/`%d` placeholders than the
Chinese it is a translation of — the failure mode being a `String(format:)` that reads
past its arguments and crashes in the one language nobody on the project speaks.

## Consequences

- A new sentence is eight edits, and the test says so before a screen does.
- **Not everything on screen is translated, on purpose.** `Controller.playerName` stays
  "手动" because it is written into a PGN tag and compared against when the file is read
  back (docs/adr/0010); translating it would make a game saved on an English phone
  unreadable on a Chinese one. Anything that round-trips through a file is a token, not a
  word.
- The layouts have to give. The eight verbs of 为什么 are one character each in Chinese
  and one row; in French they are Attaquer and Échanger, so that row wraps rather than
  squeezing seven words down to "Att…".
- Dates and numbers go through `Speech.locale`, so a library row reads 9月1日 or Sept 1
  from the same code.

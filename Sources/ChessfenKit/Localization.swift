import Foundation

/// The languages the app speaks.
///
/// Eight of them, and the list is closed: every one is a folder of words in the package's own
/// bundle, and a language nobody has written the words for is a language the app cannot speak.
/// The raw value is the folder's name — the same code iOS uses for the language, so what the
/// phone is set to and what this app can say are compared as strings without a table in between.
public enum Language: String, CaseIterable, Sendable, Identifiable, Codable {
    case chinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"

    public var id: String { rawValue }

    /// What this language calls itself. A list of languages written in one language is a list
    /// only the people who already read that language can use.
    public var endonym: String {
        switch self {
        case .chinese: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .portuguese: "Português"
        }
    }

    /// The language the words were written in first, and the one every other falls back to.
    /// A key with no translation yet says something true in Chinese rather than showing its
    /// own name to a person.
    public static let source = Language.chinese

    /// Which of these a phone asking for `codes` should be answered in, or nil for a phone that
    /// asks for nothing this app can say.
    ///
    /// Matched a code at a time in the order the phone gave them, so somebody whose second
    /// language is one of these gets it rather than the fallback. Script before region: `zh-Hant`
    /// is not `zh-Hans` and must not match it, where `fr-CA` is French and does.
    public static func matching(_ codes: [String]) -> Language? {
        for code in codes {
            let tag = code.replacingOccurrences(of: "_", with: "-")
            let parts = tag.split(separator: "-").map(String.init)
            guard let base = parts.first?.lowercased() else { continue }
            if base == "zh" {
                // Traditional Chinese is a different set of words. It is not written yet, so a
                // Hant phone falls through to whatever it asked for next.
                let script = parts.dropFirst().first?.lowercased()
                let region = parts.last?.lowercased()
                let isTraditional =
                    script == "hant" || ["tw", "hk", "mo"].contains(region ?? "")
                if !isTraditional { return .chinese }
                continue
            }
            if let match = Language.allCases.first(where: { $0.rawValue.lowercased() == base }) {
                return match
            }
        }
        return nil
    }

    /// Whether a count of `n` things takes this language's singular form.
    ///
    /// Two forms rather than CLDR's six, because these eight languages need exactly two: Chinese,
    /// Japanese and Korean never inflect for number; English, German, Spanish and Portuguese take
    /// the singular at one; French takes it at nought as well. A `.stringsdict` per language would
    /// say the same thing in two thousand lines of XML and put the words in a second file.
    func isSingular(_ n: Int) -> Bool {
        switch self {
        case .chinese, .japanese, .korean: false
        case .french: n == 0 || n == 1
        case .english, .german, .spanish, .portuguese: n == 1
        }
    }
}

/// What language the app is speaking, and the one place a word is looked up.
///
/// Global for the same reason `Sounds` is: the language is a fact about the app rather than a
/// value each screen should have to be handed, and threading a table through every view would
/// grow exactly the ritual the rest of this package exists to remove. Settable, because a person
/// can say what they want to read regardless of what the phone is set to — and because a test
/// that renders a screen has to be able to name the language it is photographing.
public enum Speech {
    /// The language every lookup answers in.
    public static var language: Language {
        get { scoped ?? box.language }
        set { box.language = newValue }
    }

    /// Everything said inside `body` is said in `language`, whatever the app is set to.
    ///
    /// A task-local rather than a second global, so two of these can be open at once without
    /// either seeing the other's language — which is what a test suite rendering one screen in
    /// eight languages does, and what a screenshot run does eight of at a time.
    public static func speaking<T>(_ language: Language, _ body: () throws -> T) rethrows -> T {
        try $scoped.withValue(language, operation: body)
    }

    public static func speaking<T>(
        _ language: Language, _ body: () async throws -> T
    ) async rethrows -> T {
        try await $scoped.withValue(language, operation: body)
    }

    @TaskLocal private static var scoped: Language?

    /// What a person chose, or nil for "whatever the phone is set to". The app remembers this
    /// across launches; the kit only holds it.
    public static var chosen: Language? {
        get { box.chosen }
        set { box.chosen = newValue }
    }

    /// What the phone asks for, answered from what this app can say.
    public static var followingSystem: Language {
        Language.matching(Locale.preferredLanguages) ?? .english
    }

    /// The locale to format numbers and dates in — the language being spoken, not the region the
    /// phone is in, so a screen reading in French does not date its games the American way.
    public static var locale: Locale { Locale(identifier: language.rawValue) }

    // ----------------------------------------------------------------- looking a word up

    /// The words of one language, as the bundle they live in. Resolved once per language: a
    /// `Bundle` is a directory listing, and re-reading it for every label on a screen is a
    /// directory listing per label.
    static func table(_ language: Language) -> Bundle? {
        box.table(language)
    }

    private static let box = Box()

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Language?
        private var choice: Language?
        private var tables: [Language: Bundle] = [:]

        var language: Language {
            get {
                lock.lock()
                defer { lock.unlock() }
                if let stored { return stored }
                let followed = Language.matching(Locale.preferredLanguages) ?? .english
                stored = followed
                return followed
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }

        var chosen: Language? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return choice
            }
            set {
                lock.lock()
                choice = newValue
                stored = newValue ?? (Language.matching(Locale.preferredLanguages) ?? .english)
                lock.unlock()
            }
        }

        func table(_ language: Language) -> Bundle? {
            lock.lock()
            defer { lock.unlock() }
            if let found = tables[language] { return found }
            // Two spellings, because SwiftPM lowercases a folder called `zh-Hans.lproj` on its
            // way into the bundle and Xcode does not.
            for candidate in [language.rawValue, language.rawValue.lowercased()] {
                guard let path = Bundle.module.path(forResource: candidate, ofType: "lproj"),
                    let bundle = Bundle(path: path)
                else { continue }
                tables[language] = bundle
                return bundle
            }
            return nil
        }
    }
}

/// One line of the app's own voice, in whichever language it is currently speaking.
///
/// The key is what the code says; the words are what the person reads, and they live in
/// `Resources/<language>.lproj/Localizable.strings` — one file per language, the same keys in
/// every one, which is what `LocalizationTests` holds them to. A key with nothing behind it in
/// the language being spoken falls back to Chinese, which the words were written in first; a key
/// with nothing behind it anywhere comes back as itself, which is visible in a screenshot rather
/// than silently blank.
public func localized(_ key: String, _ arguments: CVarArg...) -> String {
    format(phrase(key) ?? key, arguments)
}

/// The same, for a line whose shape depends on how many there are.
///
/// The count is the first thing filled into the line, because that is what these lines are
/// about. `key.one` is the singular form where a language has one — English says "1 game" and
/// "3 games", Chinese says neither — and a language with no singular simply has no `.one` key.
public func localized(_ key: String, plural count: Int, _ arguments: CVarArg...) -> String {
    let singular = Speech.language.isSingular(count) ? phrase("\(key).one") : nil
    return format(singular ?? phrase(key) ?? key, [count] + arguments)
}

/// The words behind one key, in the language being spoken or in the one they were written in —
/// nil for a key nothing anywhere has words for.
private func phrase(_ key: String) -> String? {
    let missing = "\u{0}missing"
    if let table = Speech.table(Speech.language) {
        let found = table.localizedString(forKey: key, value: missing, table: nil)
        if found != missing { return found }
    }
    if Speech.language != Language.source, let source = Speech.table(.source) {
        let found = source.localizedString(forKey: key, value: missing, table: nil)
        if found != missing { return found }
    }
    return nil
}

private func format(_ pattern: String, _ arguments: [CVarArg]) -> String {
    guard !arguments.isEmpty else { return pattern }
    return String(format: pattern, locale: Speech.locale, arguments: arguments)
}

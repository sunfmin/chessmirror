import Foundation
import Testing

@testable import ChessfenKit

/// The words, held to the one thing a table of them can be wrong about: a language that is
/// missing some.
///
/// Eight files, one per language, and the same keys in every one (docs/adr/0019). Chinese is the
/// original — every other file is measured against it, and a key that has drifted out of one of
/// them is a screen that quietly says something in the wrong language.
@Suite struct LocalizationTests {
    /// The keys and their values, read out of the file rather than through `Bundle`, so a key
    /// present-but-empty is caught as well as one missing outright.
    static func table(_ language: Language) throws -> [String: String] {
        let bundle = try #require(Speech.table(language), "no words at all for \(language.rawValue)")
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        let read = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(read as? [String: String])
    }

    @Test func everyLanguageSaysEverything() throws {
        let source = try Self.table(.chinese)
        #expect(source.count > 300, "the source table should hold the whole app's voice")
        for language in Language.allCases where language != .chinese {
            let words = try Self.table(language)
            let missing = Set(source.keys).subtracting(words.keys).sorted()
            #expect(missing.isEmpty, "\(language.rawValue) is missing \(missing)")
            // A plural form is allowed to be extra — Chinese has none — but nothing else is.
            let extra = Set(words.keys).subtracting(source.keys)
                .filter { !$0.hasSuffix(".one") }.sorted()
            #expect(extra.isEmpty, "\(language.rawValue) says things nothing asks for: \(extra)")
            let blank = words.filter { $0.value.isEmpty }.keys.sorted()
            #expect(blank.isEmpty, "\(language.rawValue) leaves \(blank) blank")
        }
    }

    /// A line with a `%d` in Chinese has to have one in French too, or the number lands nowhere.
    /// Counted rather than compared, because a translation is free to reorder them — which is
    /// what the `%1$@` spellings are for.
    @Test func everyLanguageTakesTheSameArguments() throws {
        let source = try Self.table(.chinese)
        for language in Language.allCases where language != .chinese {
            let words = try Self.table(language)
            for (key, original) in source {
                for form in [key, "\(key).one"] {
                    guard let translated = words[form] else { continue }
                    let taken = placeholders(in: translated)
                    let asked = placeholders(in: original)
                    #expect(
                        taken == asked,
                        "\(language.rawValue) \(form) takes \(taken), the original \(asked)"
                    )
                }
            }
        }
    }

    /// Which arguments a line uses, as a set of "position and kind": `%@` and `%1$@` are the
    /// same argument said two ways, and a translation may say it either way round — but a `%d`
    /// that has become a `%@` is a crash waiting for whoever reads that language.
    private func placeholders(in line: String) -> Set<String> {
        let pattern = "%(?:(\\d+)\\$)?[-+ 0#\']*[0-9.*]*(?:hh|h|ll|l|q|L|z|j|t)?([@a-zA-Z%])"
        let regex = try! NSRegularExpression(pattern: pattern)
        let whole = NSRange(line.startIndex..., in: line)
        var found: Set<String> = []
        var next = 1
        for match in regex.matches(in: line, range: whole) {
            guard let conversion = Range(match.range(at: 2), in: line).map({ line[$0] }),
                conversion != "%"
            else { continue }
            let kind: String
            switch conversion {
            case "@", "s", "S": kind = "text"
            case "f", "e", "E", "g", "G", "a", "A": kind = "number"
            default: kind = "integer"
            }
            let position = Range(match.range(at: 1), in: line).flatMap { Int(line[$0]) }
            let at = position ?? next
            next = at + 1
            found.insert("\(at) \(kind)")
        }
        return found
    }

    @Test func aPhoneIsAnsweredInWhatItAsksFor() {
        #expect(Language.matching(["fr-CA", "en"]) == .french)
        #expect(Language.matching(["zh-Hans-CN"]) == .chinese)
        #expect(Language.matching(["zh-Hant-TW", "ja-JP"]) == .japanese, "traditional is not simplified yet")
        #expect(Language.matching(["pt-BR"]) == .portuguese)
        #expect(Language.matching(["is-IS"]) == nil)
        #expect(Language.matching(["is-IS", "ko-KR"]) == .korean)
    }

    @Test func theSameLineIsSaidInEveryLanguage() {
        let said = Language.allCases.map { language in
            Speech.speaking(language) { localized("record.previous") }
        }
        #expect(
            Set(said).count == Language.allCases.count,
            "eight languages, eight sentences: \(said)"
        )
    }

    @Test func countsTakeTheirLanguageSingular() {
        Speech.speaking(.english) {
            #expect(localized("collection.games", plural: 1) == "1 game")
            #expect(localized("collection.games", plural: 3) == "3 games")
        }
        Speech.speaking(.french) {
            #expect(localized("collection.games", plural: 0).hasSuffix("partie"))
        }
        Speech.speaking(.chinese) {
            #expect(localized("collection.games", plural: 3) == "3 局")
        }
    }
}

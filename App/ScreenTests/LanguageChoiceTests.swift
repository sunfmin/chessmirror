import ChessmirrorKit
import Testing

@testable import Chessmirror

/// The half of choosing a language that is about the app's own settings being the ones the kit
/// speaks from: the choice reaches `Speech`, and the words come out of the package's bundle.
/// That a view reading the language is told when it changes is the kit's (`PlayerSettingsTests`).
@MainActor
@Suite(.serialized)
struct LanguageChoiceTests {
    @Test("the words follow the choice, and following the system means no choice at all")
    func choosingIsSpoken() {
        let settings = PlayerSettings.shared
        let before = settings.language
        defer { settings.language = before }

        settings.language = .german
        #expect(settings.currentLanguage == .german)
        #expect(Speech.language == .german)
        // Out of the package's own bundle, which is the half of this that a wrong build breaks.
        #expect(localized("record.opening") == "Anfang")
        #expect(localized("game.toPlay") == "Am Zug")

        settings.language = nil
        #expect(settings.currentLanguage == Speech.followingSystem)
        #expect(Speech.language == Speech.followingSystem)
    }
}

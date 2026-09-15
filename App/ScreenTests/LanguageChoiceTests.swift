import ChessfenKit
import Observation
import Testing

@testable import Chessfen

/// The one thing about choosing a language that a screenshot cannot show: that the screens are
/// told about it.
///
/// The root view is keyed on `LanguageSetting.current` so that every screen is rebuilt when the
/// language changes (`ChessfenApp`). That only works if reading `current` registers a dependency
/// on something observable — and it did not, for a while, because `current` answered out of the
/// kit's global instead of the app's own stored choice. The answer was right and the screens
/// never heard about it. So this reads it the way SwiftUI does.
@MainActor
@Suite(.serialized)
struct LanguageChoiceTests {
    @Test("changing the language invalidates whatever was reading it")
    func choosingIsObserved() {
        let setting = LanguageSetting.shared
        let before = setting.chosen
        defer { setting.chosen = before }

        // A box rather than a local, because `onChange` is `@Sendable`. It is called on the
        // thread doing the mutating, which is this one, so there is nothing to synchronise.
        let told = Flag()
        withObservationTracking {
            _ = setting.current
        } onChange: {
            told.raised = true
        }

        setting.chosen = setting.current == .german ? .spanish : .german

        #expect(told.raised, "a view keyed on the current language must be rebuilt when it changes")
    }

    nonisolated private final class Flag: @unchecked Sendable {
        var raised = false
    }

    @Test("the words follow the choice, and following the system means no choice at all")
    func choosingIsSpoken() {
        let setting = LanguageSetting.shared
        let before = setting.chosen
        defer { setting.chosen = before }

        setting.chosen = .german
        #expect(setting.current == .german)
        #expect(Speech.language == .german)
        // Out of the package's own bundle, which is the half of this that a wrong build breaks.
        #expect(localized("habits") == "Alte Gewohnheiten")
        #expect(localized("study.commit") == "Das ist mein Zug")

        setting.chosen = nil
        #expect(setting.current == Speech.followingSystem)
        #expect(Speech.language == Speech.followingSystem)
    }
}

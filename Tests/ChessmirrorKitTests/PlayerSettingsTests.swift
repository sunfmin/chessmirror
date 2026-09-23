import ChessmirrorKit
import Foundation
import Observation
import Testing

/// Contract: the player's settings are kept under the keys the app has always written, read back
/// by the next launch and by the next phone, set again when another device has its say, and the
/// lines keep their order whichever way they are moved (docs/adr/0012, 0027, 0038, 0045).
///
/// None of this installs the settings it builds, so nothing here moves the kit's globals — the
/// budget every search reads and the language every word comes out in are the app's settings'
/// business (`install()`), and the app's screen tests are where that is watched.
@MainActor
@Suite struct PlayerSettingsTests {
    @Test("a phone that has never set anything gets the standard settings")
    func aFreshPhoneGetsTheStandards() {
        let settings = PlayerSettings(store: InMemorySettings())
        #expect(settings.lines == JudgementLines(noSlips: false, record: 10, enqueue: 10))
        #expect(settings.strength == .elo(1400), "the bottom rung")
        #expect(settings.searchLimit == .standard)
        #expect(settings.language == nil, "follow the phone")
        #expect(settings.isSoundOn)
        #expect(settings.imports.count == PGNImport.recentGames)
        #expect(settings.imports.door.isEmpty)
        #expect(settings.imports.names.isEmpty)
    }

    /// Every value goes into the store under the key an earlier build wrote, in the form it wrote
    /// it, so a phone that updates keeps what it had — and the next launch reads it all back.
    @Test("what is set is kept under the old keys, and the next launch reads it back")
    func whatIsSetIsKept() {
        let store = InMemorySettings()
        let settings = PlayerSettings(store: store)
        settings.record = 15
        settings.enqueue = 25
        settings.strength = .elo(2200)
        settings.searchLimit = SearchLimit(seconds: 5, depth: 12, stop: .time)
        settings.language = .japanese
        settings.isSoundOn = false
        settings.imports.count = 20
        settings.imports.door = "chesscom"

        #expect(store.values["chessmirror.line.record"] as? Double == 15)
        #expect(store.values["chessmirror.line.enqueue"] as? Double == 25)
        #expect(store.values["chessmirror.strength"] as? String == "2200")
        #expect(store.values["chessmirror.search"] as? String == "5 12 time")
        #expect(store.values["chessmirror.language"] as? String == "ja")
        #expect(store.values["chessmirror.sound"] as? Bool == false)
        #expect(store.values["chessmirror.import.count"] as? Int == 20)
        #expect(store.values["chessmirror.import.door"] as? String == "chesscom")

        let relaunched = PlayerSettings(store: store)
        #expect(relaunched.lines == settings.lines)
        #expect(relaunched.strength == .elo(2200))
        #expect(relaunched.searchLimit == settings.searchLimit)
        #expect(relaunched.language == .japanese)
        #expect(!relaunched.isSoundOn)
        #expect(relaunched.imports.count == 20)
        #expect(relaunched.imports.door == "chesscom")

        settings.language = nil
        #expect(store.values["chessmirror.language"] == nil, "following the phone is no key at all")
    }

    /// 入列线 never sits below 记录线 — raised with it, and refused below it — and a store holding
    /// the two the wrong way round is read the right way round.
    @Test("入列线 is dragged up with 记录线 and never set below it")
    func theEnrolLineFollowsTheRecordLine() {
        let store = InMemorySettings()
        let settings = PlayerSettings(store: store)
        settings.record = 20
        #expect(settings.enqueue == 20, "dragged up")
        #expect(store.values["chessmirror.line.enqueue"] as? Double == 20, "and kept so")
        settings.enqueue = 5
        #expect(settings.enqueue == 20, "not set below")
        settings.record = 10
        #expect(settings.enqueue == 20, "lowering 记录线 leaves 入列线 where it was")

        let crossed = PlayerSettings(store: InMemorySettings([
            "chessmirror.line.record": 25.0, "chessmirror.line.enqueue": 10.0,
        ]))
        #expect(crossed.enqueue == 25)
    }

    /// Another phone had its say: what it wrote is set here, what it did not write stays, and a
    /// language it took away is the phone's language again.
    @Test("what another device writes arrives, and what it did not write stays")
    func anotherDeviceHasItsSay() {
        let store = InMemorySettings()
        let settings = PlayerSettings(store: store)
        settings.language = .french
        settings.searchLimit = SearchLimit(seconds: 30, depth: 24, stop: .depth)

        store.arrive("1400", forKey: "chessmirror.strength")
        #expect(settings.strength == .elo(1400))
        #expect(settings.searchLimit == SearchLimit(seconds: 30, depth: 24, stop: .depth), "untouched")

        store.arrive(false, forKey: "chessmirror.sound")
        #expect(!settings.isSoundOn)

        store.arrive(nil, forKey: "chessmirror.language")
        #expect(settings.language == nil)

        let names = try? JSONEncoder().encode(["lichess": ["DrNykterstein"]])
        store.arrive(names, forKey: "chessmirror.import.names")
        #expect(settings.imports.latest(on: .lichess) == "DrNykterstein")
    }

    /// The rung picked is the one the next game starts at, on this phone and on the next one.
    @Test("the rung picked is remembered, and a fresh phone starts at the bottom rung")
    func theRungIsRemembered() {
        let store = InMemorySettings()
        let settings = PlayerSettings(store: store)
        #expect(settings.strength == Strength.ladder.first, "nothing picked yet")
        settings.strength = .elo(2200)
        #expect(PlayerSettings(store: store).strength == .elo(2200))
        #expect(PlayerSettings(store: InMemorySettings()).strength == .elo(1400))
        settings.strength = .full
        #expect(PlayerSettings(store: store).strength == .full, "满力 picked is 满力 kept, not the default")
    }

    /// An account is kept once it has fetched, newest first, four to a site, spelt as it was
    /// typed the last time, and struck off when asked.
    @Test("accounts are kept newest first, four to a site")
    func accountsAreKeptNewestFirst() {
        let store = InMemorySettings()
        let memory = PlayerSettings(store: store).imports
        memory.remember("sunfmin", on: .lichess)
        memory.remember("  DrNykterstein ", on: .lichess)
        #expect(memory.names[.lichess] == ["DrNykterstein", "sunfmin"])
        memory.remember("SUNFMIN", on: .lichess)
        #expect(memory.names[.lichess] == ["SUNFMIN", "DrNykterstein"], "one account, spelt the newest way")
        memory.remember("", on: .lichess)
        #expect(memory.names[.lichess]?.count == 2, "a blank is not an account")
        for name in ["a", "b", "c", "d"] { memory.remember(name, on: .lichess) }
        #expect(memory.names[.lichess] == ["d", "c", "b", "a"])
        #expect(memory.latest(on: .chessCom) == nil, "each site its own")
        memory.forget("C", on: .lichess)
        #expect(memory.names[.lichess] == ["d", "b", "a"])

        #expect(PlayerSettings(store: store).imports.names[.lichess] == ["d", "b", "a"],
                "and the next launch has them")
    }

    /// A view reading the language the app speaks is told when it changes — the root view is
    /// keyed on it, and a read that registered nothing left every screen in the old language.
    @Test("changing the language invalidates whatever was reading it")
    func choosingIsObserved() {
        let settings = PlayerSettings(store: InMemorySettings())
        let told = Flag()
        withObservationTracking {
            _ = settings.currentLanguage
        } onChange: {
            told.raised = true
        }
        settings.language = settings.currentLanguage == .german ? .spanish : .german
        #expect(told.raised, "a view keyed on the current language must be rebuilt when it changes")
    }

    nonisolated private final class Flag: @unchecked Sendable {
        var raised = false
    }
}

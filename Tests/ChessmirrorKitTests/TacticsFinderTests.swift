@testable import ChessmirrorKit
import Foundation
import Testing
import ChessmirrorKitTesting

@Suite(.speaking(.chinese)) struct TacticsFinderTests {
    /// White queen on d1, black rook hanging on d5: a shot the rules can name unaided.
    private static let hangingRook = "4k3/8/8/3r4/8/8/8/3QK3 w - - 0 1"

    private func game(_ fen: String) throws -> Game {
        try #require(Game(startFEN: fen))
    }

    /// A search that agrees with the rules about the capture.
    private func takesTheRook() -> Analysis {
        Analysis(
            depth: PositionSearches.depth,
            lines: [Line(score: .centipawns(500), uciMoves: ["d1d5"], san: ["Qxd5"])]
        )
    }

    @Test("a new finder is off and says nothing")
    func startsOff() {
        let finder = TacticsFinder()
        #expect(!finder.isOn)
        #expect(finder.tactic == nil)
        #expect(!finder.isProbing)
        #expect(finder.probedAnalysis == nil)
        #expect(finder.prompt(ourTurn: true) == nil)
    }

    @Test("the position moving on takes the shot, the probe and the probe's Analysis with it")
    func forgettingClearsAllThree() throws {
        var finder = TacticsFinder()
        finder.turnOn()
        finder.propose(in: try game(Self.hangingRook))
        finder.confirm(in: try game(Self.hangingRook), analysis: takesTheRook())
        #expect(finder.tactic != nil)
        #expect(finder.probedAnalysis != nil)

        finder.forget()
        #expect(finder.tactic == nil)
        #expect(!finder.isProbing)
        #expect(finder.probedAnalysis == nil)
        // The switch is not a thing the board moving on may throw.
        #expect(finder.isOn)
    }

    @Test("while the probe runs with nothing named yet, the strip says it is looking")
    func proposingWithNoShotReadsAsChecking() throws {
        var finder = TacticsFinder()
        finder.turnOn()
        // An empty board for the side to move: the rules have nothing to propose.
        finder.propose(in: try game("4k3/8/8/8/8/8/8/4K3 w - - 0 1"))
        #expect(finder.tactic == nil)
        #expect(finder.isProbing)
        #expect(finder.prompt(ourTurn: true) == localized("finder.checking"))
    }

    @Test("a named shot is read out as ours or theirs")
    func promptNamesWhoseMoveItIs() throws {
        var finder = TacticsFinder()
        finder.turnOn()
        finder.propose(in: try game(Self.hangingRook))
        let ours = try #require(finder.prompt(ourTurn: true))
        let theirs = try #require(finder.prompt(ourTurn: false))
        #expect(ours.hasPrefix(localized("finder.ours")))
        #expect(theirs.hasPrefix(localized("finder.theirs")))
        #expect(ours.contains(try #require(finder.tactic).sentence))
    }

    @Test("a settled probe that found nothing says so rather than going on looking")
    func settlingWithNothingReadsAsNone() throws {
        var finder = TacticsFinder()
        finder.turnOn()
        finder.propose(in: try game("4k3/8/8/8/8/8/8/4K3 w - - 0 1"))
        finder.settle()
        #expect(!finder.isProbing)
        #expect(finder.prompt(ourTurn: true) == localized("finder.none"))
    }

    @Test("confirming leaves the probe running: a standing Analysis is not the search ending")
    func confirmingDoesNotSettleTheProbe() throws {
        var finder = TacticsFinder()
        finder.turnOn()
        finder.propose(in: try game(Self.hangingRook))
        finder.confirm(in: try game(Self.hangingRook), analysis: takesTheRook())
        #expect(finder.isProbing)
        #expect(try #require(finder.tactic).move.uci == "d1d5")
        #expect(finder.probedAnalysis != nil)
    }

    @Test("the switch going off takes the shot and the arrival with it")
    func turningOffForgetsEverything() throws {
        var finder = TacticsFinder()
        finder.turnOn()
        finder.rememberArrival()
        finder.propose(in: try game(Self.hangingRook))
        finder.confirm(in: try game(Self.hangingRook), analysis: takesTheRook())

        finder.turnOff()
        #expect(!finder.isOn)
        #expect(!finder.openedByArrival)
        #expect(finder.tactic == nil)
        #expect(!finder.isProbing)
        #expect(finder.probedAnalysis == nil)
        #expect(finder.prompt(ourTurn: true) == nil)
    }

    @Test("only what arriving turned on is remembered as arriving's to put back")
    func arrivalIsOnlyRememberedWhenTheSwitchMoved() {
        var pressedByHand = TacticsFinder()
        pressedByHand.turnOn()
        #expect(!pressedByHand.openedByArrival)

        var swipedOnto = TacticsFinder()
        swipedOnto.turnOn()
        swipedOnto.rememberArrival()
        #expect(swipedOnto.openedByArrival)

        // A switch that never moved was not opened by the arrival either.
        var stillOff = TacticsFinder()
        stillOff.rememberArrival()
        #expect(!stillOff.openedByArrival)
    }
}

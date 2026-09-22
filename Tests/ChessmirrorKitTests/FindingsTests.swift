import Testing
@testable import ChessmirrorKit

@Suite struct FindingsTests {
    @Test func aCardOpensOnAPositionAndShutsOnAnother() {
        var findings = Findings()
        #expect(findings.openCard(on: "fen-a") == nil)
        let opened = findings.press(.tactics, on: "fen-a")
        #expect(opened)
        #expect(findings.openCard(on: "fen-a") == .tactics)
        #expect(findings.openCard(on: "fen-b") == nil, "nothing opened on one position is open on another")
    }

    @Test func pressingTheOpenCardShutsItWithoutCountingASecondOpen() {
        var findings = Findings()
        let opened = findings.press(.mate, on: "fen")
        #expect(opened)
        let reopened = findings.press(.mate, on: "fen")
        #expect(!reopened, "the second press shuts")
        #expect(findings.openCard(on: "fen") == nil)
    }

    @Test func theLineTogglesOnlyWhileSomethingIsOpen() {
        var findings = Findings()
        findings.toggleLine()
        findings.press(.tactics, on: "fen")
        #expect(findings.draws(.tactics, on: "fen"))
        findings.toggleLine()
        #expect(!findings.draws(.tactics, on: "fen"))
        #expect(findings.openCard(on: "fen") == .tactics, "the card stays open with its line off")
    }

    @Test func forgettingPutsEveryCardAway() {
        var findings = Findings()
        findings.press(.tactics, on: "fen")
        findings.isDealt = true
        findings.forget()
        #expect(findings.openCard(on: "fen") == nil)
        #expect(findings.isDealt, "forgetting the eye's position is not undealing the deck")
    }
}

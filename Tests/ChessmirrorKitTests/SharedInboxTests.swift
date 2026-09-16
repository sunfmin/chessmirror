import ChessmirrorKit
import Foundation
import Testing

/// The folder a share extension and the app both see, which is the whole of the handoff
/// between them (docs/adr/0033).

private func temporaryInbox() -> SharedInbox {
    let url = URL(filePath: NSTemporaryDirectory())
        .appending(path: "chessmirror-inbox-\(UUID().uuidString)", directoryHint: .isDirectory)
    return SharedInbox(url: url)
}

@Test("a picture written by the extension is what the app reads back")
func aSharedPictureSurvivesTheHandoff() throws {
    let inbox = temporaryInbox()
    defer { try? FileManager.default.removeItem(at: inbox.url) }

    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    try inbox.deposit(bytes)
    #expect(inbox.waiting().count == 1)
    #expect(inbox.takeNewest() == bytes)
}

@Test("a picture the app has taken does not arrive a second time")
func takingOneEmptiesIt() throws {
    let inbox = temporaryInbox()
    defer { try? FileManager.default.removeItem(at: inbox.url) }

    try inbox.deposit(Data([1]))
    #expect(inbox.takeNewest() != nil)
    #expect(inbox.waiting().isEmpty, "removed as it was read, not after it was looked at")
    #expect(inbox.takeNewest() == nil)
}

@Test("three shares in a row hand over the last one")
func theNewestIsTheOneWanted() async throws {
    let inbox = temporaryInbox()
    defer { try? FileManager.default.removeItem(at: inbox.url) }

    for byte in UInt8(1)...3 {
        try inbox.deposit(Data([byte]))
        // The names carry milliseconds, and three writes can land inside one.
        try? await Task.sleep(for: .milliseconds(3))
    }
    #expect(inbox.waiting().count == 3)
    #expect(inbox.takeNewest() == Data([3]))
    inbox.empty()
    #expect(inbox.waiting().isEmpty, "and the ones nobody is going to look at are dropped")
}

@Test("an empty inbox says nothing rather than failing")
func anEmptyInboxIsQuiet() {
    let inbox = temporaryInbox()
    #expect(inbox.waiting().isEmpty, "a folder that was never written is not an error")
    #expect(inbox.takeNewest() == nil)
    inbox.empty()
}

@Test("a shared screenshot reaches the Confirm Position screen")
func aSharedScreenshotReachesTheGate() async throws {
    let inbox = temporaryInbox()
    defer { try? FileManager.default.removeItem(at: inbox.url) }

    // The bytes a share extension would have been handed: a PNG of a lichess board. This one
    // holds a black king and a white knight and no white king, so it is a legal *reading* of
    // an illegal position — which opens the editor rather than a game (docs/adr/0008,
    // docs/adr/0011), and is the door the criterion names.
    let url = try #require(Bundle.module.url(forResource: "reference_board", withExtension: "png"))
    try inbox.deposit(try Data(contentsOf: url))

    let shared = try #require(inbox.takeNewest())
    let intake = await BoardIntake.read(.data(shared))
    guard case .needsEditing(let draft, let shaky, _, _) = intake else {
        Issue.record("a shared board has to reach the gate, got \(intake)")
        return
    }
    #expect(draft.fen.hasPrefix("r3k3/2N5/8/8/8/8/8/8"))
    #expect(shaky.isEmpty, "and no orange rings on clean pixels")
}

@Test("a shared board that is a legal position opens straight as a game")
func aSharedLegalBoardOpensAsAGame() async throws {
    let inbox = temporaryInbox()
    defer { try? FileManager.default.removeItem(at: inbox.url) }

    let fen = playout(seed: 7, plies: 20)
    let drawn = try #require(BoardRenderer.image(fen: fen, options: BoardRenderer.Options()))
    try inbox.deposit(try #require(drawn.pngData))

    let shared = try #require(inbox.takeNewest())
    let intake = await BoardIntake.read(.data(shared))
    guard case .played(let game, let shaky, _, _) = intake else {
        Issue.record("a legal board opens as a game, got \(intake)")
        return
    }
    #expect(withoutHistory(game.state.fen).split(separator: " ").first == fen.split(separator: " ").first)
    #expect(shaky.isEmpty)
}

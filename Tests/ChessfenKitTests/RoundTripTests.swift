import ChessfenKit
import Testing

/// Render a Position, recognise it back, demand the same FEN.
///
/// This covers the whole pipeline — board location, square segmentation, piece colour and
/// shape matching, FEN assembly — against boards that vary in size, palette, coordinates
/// and Orientation.

private let positions: [String: String] = [
    "start": PGN.standardStartFEN,
    "empty": "8/8/8/8/8/8/8/8 w - - 0 1",
    "opening": playout(seed: 1, plies: 8),
    "middlegame": playout(seed: 2, plies: 30),
    "endgame": playout(seed: 3, plies: 70),
    "lone-kings": "4k3/8/8/8/8/8/8/4K3 w - - 0 1",
    "promotion-mess": "QQQQQQQQ/8/8/4k3/3K4/8/8/qqqqqqqq w - - 0 1",
]

@Test(
    "a rendered position is recognised back exactly",
    arguments: [
        "start", "empty", "opening", "middlegame", "endgame", "lone-kings",
        "promotion-mess",
    ]
)
func positionsRoundTrip(name: String) throws {
    // Orientation is pinned: "promotion-mess" has white on the eighth rank, which is
    // exactly the case no picture can resolve. Inference is tested on its own below.
    let fen = try #require(positions[name])
    #expect(try readBack(fen, orientation: .whiteAtBottom) == withoutHistory(fen))
}

@Test(
    "the palette does not have to be the one the recogniser was written against",
    arguments: [
        // Default, lichess blue, chess.com green, near-white, and a dark theme.
        ("#ffce9e", "#d18b47"),
        ("#dee3e6", "#8ca2ad"),
        ("#eeeed2", "#769656"),
        ("#ffffff", "#dcdcdc"),
        ("#6d6d6d", "#3d3d3d"),
    ]
)
func palettesRoundTrip(light: String, dark: String) throws {
    let fen = try #require(positions["middlegame"])
    var style = BoardStyle()
    style.lightSquare = light
    style.darkSquare = dark
    let options = BoardRenderer.Options(style: style)
    #expect(try readBack(fen, options: options) == withoutHistory(fen))
}

@Test("boards from tiny to large round trip", arguments: [200, 320, 480, 800])
func sizesRoundTrip(size: Int) throws {
    let fen = try #require(positions["opening"])
    let options = BoardRenderer.Options(size: size)
    #expect(try readBack(fen, options: options) == withoutHistory(fen))
}

@Test("a coordinate margin is cropped away rather than read as squares")
func coordinateMarginIsCroppedAway() throws {
    let fen = try #require(positions["middlegame"])
    let options = BoardRenderer.Options(size: 600, coordinates: true)
    #expect(try readBack(fen, options: options) == withoutHistory(fen))
}

@Test("a flat highlight does not confuse the piece standing on it")
func flatHighlightIsSeenThrough() throws {
    // The common case: a last-move or selection tint, flat fill, as on lichess and
    // chess.com. The reference screenshot adds a frame on top of one, and works too.
    let fen = "4k3/8/8/8/8/8/4r3/4K3 w - - 0 1"
    let square = try #require(Square("e1"))
    let options = BoardRenderer.Options(highlights: [BoardHighlight(square: square)])
    #expect(try readBack(fen, options: options) == withoutHistory(fen))
}

@Test("a radial check halo is admitted as shaky rather than guessed at")
func haloHighlightIsReportedAsShaky() throws {
    // A radial halo breaks the flat-background assumption. Being wrong here is a known
    // limitation; being wrong *quietly* would not be acceptable.
    let fen = "4k3/8/8/8/8/8/4r3/4K3 w - - 0 1"
    let square = try #require(Square("e1"))
    let options = BoardRenderer.Options(
        highlights: [BoardHighlight(square: square, style: .halo)]
    )
    let image = try #require(BoardRenderer.image(fen: fen, options: options))
    let result = try Recognizer.recognise(
        image, orientation: .whiteAtBottom, castling: .none
    )
    #expect(result.shaky.contains { $0.square == square })
}

@Test("a board seen from black's side round trips when told so")
func flippedBoardRoundTripsWhenTold() throws {
    let fen = try #require(positions["opening"])
    let options = BoardRenderer.Options(orientation: .blackAtBottom)
    #expect(try readBack(fen, options: options, orientation: .blackAtBottom) == withoutHistory(fen))
}

@Test("a board seen from black's side is spotted from where the armies sit")
func flippedBoardIsInferred() throws {
    // A flip is a point reflection, so only the layout of the two armies can betray it.
    let fen = PGN.standardStartFEN
    let options = BoardRenderer.Options(orientation: .blackAtBottom)
    #expect(try readBack(fen, options: options) == withoutHistory(fen))
}

@Test("what comes out of the recogniser is a position the rules accept")
func recognisedPositionsAreUsable() throws {
    let fen = try #require(positions["middlegame"])
    let image = try #require(BoardRenderer.image(fen: fen))
    let result = try Recognizer.recognise(image, orientation: .whiteAtBottom)
    #expect(Rules.validate(fen: result.fen).isUsable)
}

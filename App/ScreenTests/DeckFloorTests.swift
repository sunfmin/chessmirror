import ChessfenKit
import SwiftUI
import Testing
import UIKit

@testable import Chessfen

/// The room the deck under the board is given, held to the one thing that has to be true of it.
///
/// Numbers and a pixel probe rather than a photograph, because the failure they guard against is
/// silent: a screen short enough that the board kept its own minimum left the deck nothing, and a
/// deck with no room is not a smaller deck — it is `opacity(0)`, with every card's actions gone and
/// nothing in the accessibility tree to say so. The deck is the bottom of this screen and the board
/// is the thing that gives way to it (docs/adr/0025).
@MainActor
@Suite(.serialized, .speaking(.chinese))
struct DeckFloor {
    /// Every screen the app can be held on, as (name, width, glass height, top chrome, bottom
    /// inset). Top chrome is the status bar plus an inline navigation bar; the bottom inset is the
    /// home indicator, which the board is sized against.
    ///
    /// Only the 402×874 row is measured — this suite's own device, read back off `game-in-play.png`
    /// by `cardHeight` and `namesEdges`. The rest are Apple's safe-area insets for those screens,
    /// and every one of them is stated in the direction that makes the test harder: a shorter
    /// reader is a smaller deck, and the board's own minimum is what eats it.
    private static let screens:
        [(name: String, width: CGFloat, glass: CGFloat, top: CGFloat, bottom: CGFloat)] = [
            ("iPhone SE", 375, 667, 64, 0),
            ("iPhone 13 mini", 375, 812, 94, 34),
            ("iPhone 17", 402, 874, 116, 34),
            ("iPhone 17 Pro Max", 440, 956, 116, 34),
            ("iPad mini, portrait", 744, 1133, 74, 20),
            ("iPad Pro 13, portrait", 1032, 1376, 74, 20),
            ("iPad Pro 13, on its side", 1376, 1032, 74, 20),
        ]

    // ------------------------------------------------------------- what the numbers are

    @Test("the board yields to the deck on every screen the app runs on")
    func boardYieldsToTheDeck() {
        for screen in Self.screens {
            let reader = screen.glass - screen.top - screen.bottom
            let room = GameScreen.deckRoom(readerHeight: reader, width: screen.width)
            let card = room - GameScreen.railReserve
            let board = GameScreen.boardSide(in: CGSize(width: screen.width, height: reader))

            // The floor first, because it is the promise: the deck is never given nothing.
            #expect(
                card >= GameScreen.cardFloor, "\(screen.name) left the card \(card)pt of \(room)pt"
            )
            // And the board is still a board, and still fits the width it is drawn in.
            #expect(board >= GameScreen.minBoard, "\(screen.name): board \(board)pt")
            #expect(board <= screen.width - 8, "\(screen.name): board \(board)pt is off the glass")
        }
    }

    /// The tightest screen, to the point. The board is on its own minimum here, so this is the
    /// smallest card anybody can be looking at — and the number the floor was chosen under, which
    /// is why it is written down: a floor that is doing work is a floor that has been hit.
    @Test("an iPhone SE's card is about 137pt, and the floor is under it")
    func shortestScreenIsStillACard() {
        let card =
            GameScreen.deckRoom(readerHeight: 667 - 64, width: 375) - GameScreen.railReserve
        #expect(abs(card - 137) <= 8, "an iPhone SE's card came out at \(card)pt")
    }

    /// Why the phone is held in portrait (docs/adr/0025). This is the failure the picture suite
    /// could not see: nothing on the screen says the deck has gone.
    @Test("a phone on its side has no room for a deck")
    func aPhoneOnItsSideHasNoRoom() {
        let room = GameScreen.deckRoom(readerHeight: 402 - 44, width: 874)
        #expect(room < GameScreen.cardFloor, "the deck would have been left \(room)pt")
    }

    @Test("the phone is held in portrait, and the iPad keeps all four ways up")
    func portraitOnly() throws {
        // The plist *file* in the app bundle rather than `Bundle.main`'s dictionary: iOS resolves
        // the `~ipad` keys out of that dictionary on the device it is running on, so on this iPhone
        // the iPad's list is not in it at all. The file on disk is the one place both are readable
        // at once — and it is the artifact that ships, which is the thing worth holding.
        let url = Bundle.main.bundleURL.appending(path: "Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])

        let phone = try #require(plist["UISupportedInterfaceOrientations"] as? [String])
        #expect(
            phone == ["UIInterfaceOrientationPortrait"],
            "a phone on its side has no room for the deck, and what it did about that was vanish"
        )
        let pad = try #require(plist["UISupportedInterfaceOrientations~ipad"] as? [String])
        #expect(
            Set(pad) == Set([
                "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
            ]),
            "the iPad has the height for all four, so it keeps them"
        )
    }

    // ------------------------------------------------------------------ the screen

    private static let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]

    /// The same shape of opinion `game-in-play` is photographed with — one Line with a continuation,
    /// because 要害 reads the squares a move mattered over off the rest of it (docs/adr/0021) — so
    /// the card in front is as full as a card gets.
    private static let searching = [
        Analysis(
            depth: 26,
            selectiveDepth: 34,
            lines: [
                Line(
                    score: .centipawns(38),
                    uciMoves: ["d2d4", "e5d4", "c3d4", "c5b6", "e4e5", "d7d5"],
                    san: ["d4", "exd4", "cxd4", "Bb6", "e5", "d5"]
                )
            ],
            nodes: 63_400_000,
            nodesPerSecond: 2_480_000,
            timeMilliseconds: 25_600
        )
    ]

    private func session() throws -> GameSession {
        let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
        let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine])
        session.setPractising(false)
        return session
    }

    private func screen(_ session: GameSession) -> some View {
        NavigationStack {
            GameScreen(session: session, path: .constant([]))
        }
        .environment(EngineHost(ScriptedEngine(Self.searching, isEndless: true)))
        .environment(GameLibrary())
    }

    /// The phone the app is most likely to be held on but is least likely to be designed against:
    /// 375×667 is the shortest glass iOS 26 runs on. A window of a stated size has no scene and so
    /// no safe areas of its own — which is exactly what an iPhone with a Home button has, though the
    /// status bar SwiftUI insets it by is the one this simulator wears, so this picture is a little
    /// shorter than the real thing. What it is good for is the other direction: the room the layout
    /// gives the deck, against the room the arithmetic says it has.
    @Test("the shortest phone still gets a card, and the board is what pays for it")
    func shortestPhoneKeepsItsCard() async throws {
        let size = CGSize(width: 375, height: 667)
        let session = try session()
        let rendered = await ScreenImage.write("deck-small-phone", size: size) { screen(session) }

        for name in ["要害", "杀招", "战术", "五步", "练习"] {
            #expect(rendered.says(name), "the names are the only way to the other four cards")
        }
        #expect(rendered.says("正在算"), "and the card in front of them is a card")

        let card = try #require(cardHeight(of: rendered.url, in: size), "no card in the picture")
        let reader = try #require(readerHeight(of: rendered.url, in: size), "no top of the column")
        let arithmetic =
            GameScreen.deckRoom(readerHeight: reader, width: size.width) - GameScreen.railReserve
        // The picture against the sum. `chrome` and `railReserve` are the heights of nine views the
        // test cannot see, added up by hand: a row that grows without being paid for there is a row
        // that eats the deck, and this is what says so.
        #expect(
            abs(card - arithmetic) <= 8,
            "the card is \(card)pt where the column's own sum says \(arithmetic)pt"
        )
        // And the board is what gave way for it: on this width the board is at its minimum, which is
        // the branch that used to hand the deck the bill.
        let board = GameScreen.boardSide(in: CGSize(width: size.width, height: reader))
        #expect(board == GameScreen.minBoard, "the board was \(board)pt on the shortest phone")
    }

    /// The reader's own text size, which is the one thing about a phone a picture suite otherwise
    /// never varies — and the size at which five names in one capsule stop fitting if the row is
    /// allowed to grow without limit.
    @Test("the five names fit inside the glass at the largest text size")
    func namesFitAtTheLargestText() async throws {
        let size = CGSize(width: 402, height: 874)
        let session = try session()
        let rendered = await ScreenImage.write("deck-large-text", size: size) {
            screen(session).dynamicTypeSize(.accessibility5)
        }

        for name in ["要害", "杀招", "战术", "五步", "练习"] {
            #expect(rendered.says(name))
        }

        let names = try #require(railBounds(of: rendered.url, in: size))
        // A capsule that has run off both edges still reads all five names out to VoiceOver, and
        // 练习 is simply not there to press: the margin is the only witness there is.
        #expect(names.left > 8, "the names start \(names.left)pt in, at the edge of the glass")
        #expect(
            size.width - names.right > 8,
            "the names run \(size.width - names.right)pt from the other edge"
        )
        #expect(names.bottom > 2, "the names are sitting on the glass edge")

        // And the card is still a card. The rows above it grow with the reader too, and they are the
        // ones that would eat the deck if nothing capped them: at the largest size they took the
        // card down to 42pt, which is a card that shows one line of itself and nothing else.
        let card = try #require(cardHeight(of: rendered.url, in: size), "no card at large text")
        #expect(card >= GameScreen.cardFloor, "the card was \(card)pt at the largest text size")
    }

    // ------------------------------------------------------------------- glue

    /// The picture as RGBA bytes, so a test can ask it what it drew.
    private func raster(of url: URL) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }

    /// The five names: their left and right edges, and how far their lowest pixel sits above the
    /// bottom of the glass — all in points.
    ///
    /// Told apart by colour. The capsule is walnut at a tenth over parchment (233,220,206), the pill
    /// and the letters standing in it are ink, and the band is the bottom 40pt of the screen, where
    /// nothing else is either — the card ends 48pt up, because the names are the last thing on it.
    private func railBounds(
        of url: URL, in size: CGSize
    ) -> (left: CGFloat, right: CGFloat, bottom: CGFloat)? {
        guard let (pixels, width, height) = raster(of: url) else { return nil }
        let scale = CGFloat(width) / size.width
        let band = Int(40 * scale)
        var left = width
        var right = -1
        var lowest = -1
        for row in max(0, height - band)..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                let names =
                    (abs(r - 233) <= 12 && abs(g - 220) <= 12 && abs(b - 206) <= 12)
                    || (r + g + b) / 3 < 120
                if names {
                    left = min(left, column)
                    right = max(right, column)
                    lowest = max(lowest, row)
                }
            }
        }
        guard lowest >= 0 else { return nil }
        return (CGFloat(left) / scale, CGFloat(right) / scale, CGFloat(height - 1 - lowest) / scale)
    }

    /// How tall the column the layout was handed is, in points, read off the picture.
    ///
    /// The column starts at the navigation bar's bottom edge, and the first thing on it is a player
    /// bar wearing a hairline across its top — so its first row is the first row of the picture
    /// whose left-hand end is not the page. The glass less that row is the height every part of the
    /// deck's arithmetic is stated in, which is what makes it comparable with `deckRoom`.
    private func readerHeight(of url: URL, in size: CGSize) -> CGFloat? {
        guard let (pixels, width, height) = raster(of: url) else { return nil }
        let scale = CGFloat(width) / size.width
        for row in 0..<height {
            var offPage = 0
            for column in [5, 15, 25] {
                let offset = (row * width + column) * 4
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                if !(abs(r - 247) <= 8 && abs(g - 237) <= 8 && abs(b - 225) <= 8) { offPage += 1 }
            }
            if offPage >= 2 { return CGFloat(height - row) / scale }
        }
        return nil
    }

    /// How tall the card in front of those names is, in points, read off the picture.
    ///
    /// The card is a raised panel (255,247,238) and so is the bar of whichever side is on the clock,
    /// which is why this looks for the *lowest* long run of rows that are mostly that colour: the
    /// record sits between the two and is not raised, so the two can never be one run.
    private func cardHeight(of url: URL, in size: CGSize) -> CGFloat? {
        guard let (pixels, width, height) = raster(of: url) else { return nil }
        let scale = CGFloat(width) / size.width
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for row in 0..<height {
            var raised = 0
            for column in stride(from: 0, to: width, by: 3) {
                let offset = (row * width + column) * 4
                if abs(Int(pixels[offset]) - 255) <= 3,
                    abs(Int(pixels[offset + 1]) - 247) <= 3,
                    abs(Int(pixels[offset + 2]) - 238) <= 3
                {
                    raised += 1
                }
            }
            let isCard = raised * 3 > width / 2
            switch (isCard, start) {
            case (true, nil): start = row
            case (false, .some(let from)):
                if row - from > Int(30 * scale) { runs.append(from...(row - 1)) }
                start = nil
            default: break
            }
        }
        if let from = start, height - from > Int(30 * scale) { runs.append(from...(height - 1)) }
        guard let card = runs.last else { return nil }
        return CGFloat(card.count) / scale
    }
}

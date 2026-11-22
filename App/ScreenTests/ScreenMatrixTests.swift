import ChessmirrorKit
import Foundation
import SwiftUI
import Testing

@testable import Chessmirror
import ChessmirrorKitTesting

/// Every screen, once in each way a phone can differ from the one the other suites draw on: in
/// the dark, at an accessibility text size, on the smallest iPhone iOS 26 runs on, and in each of
/// the eight languages the app speaks. Each row is a row of its own, not multiplied by the others.
///
/// What every one of them is held to is the layout, not the words (the screens' own suites hold
/// those): everything labelled is inside the window's safe area, no two labelled things overlap,
/// and every control is at least 44×44 pt. A screen that keeps its words but drops them on top of
/// each other in German, or under the clock at the larger text size, fails here.
@MainActor
// No `.drawing(in:)` on the suite: its task-local language would outrank the one each case sets
// below, and a case names its own language (Speaking.swift says why a drawing sets the global).
@Suite(.serialized)
struct ScreenMatrix {
    /// One way the phone differs from the iPhone 17 in light mode at the default text size.
    nonisolated enum Row: Equatable, CustomTestStringConvertible, Sendable {
        case dark
        case accessibilityText
        case smallestPhone
        case language(Language)

        static let all: [Row] = [.dark, .accessibilityText, .smallestPhone] + Language.allCases.map(Row.language)

        var testDescription: String {
            switch self {
            case .dark: "dark"
            case .accessibilityText: "a11y3"
            case .smallestPhone: "375x667"
            case .language(let language): language.rawValue
            }
        }

        var style: UIUserInterfaceStyle { self == .dark ? .dark : .light }
        /// The iPhone SE's screen, the smallest the deployment target supports. A window of a stated
        /// size has no safe areas, which is that phone exactly: it has a Home button.
        var size: CGSize? { self == .smallestPhone ? CGSize(width: 375, height: 667) : nil }
        var typeSize: DynamicTypeSize { self == .accessibilityText ? .accessibility3 : .large }
        var language: Language {
            if case .language(let language) = self { return language }
            return .chinese
        }
    }

    /// The app's screens, each set up with something on it.
    nonisolated enum Screen: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case library, book, about, game, drill, editor, collection, importSheet
        var testDescription: String { rawValue }

        /// A word only this screen says, in whatever language it is drawn in: that the language
        /// reached the screen at all.
        var ownWord: String {
            switch self {
            case .library: localized("library.photograph")
            case .book: localized("book")
            case .about: localized("about")
            case .game: localized("game.toPlay")
            case .drill: localized("standing.bar")
            case .editor: localized("edit.title")
            case .collection: localized("collection.favourites")
            case .importSheet: localized("import.title")
            }
        }

        /// The names this screen draws that a squeezed layout broke (chessmirror#32), each in the
        /// face it is set in at the row's text size.
        @MainActor func names(at row: Row) -> [Name] {
            let size = row.typeSize
            switch self {
            case .importSheet:
                return ImportDoors.Door.allCases.map { door in
                    Name(text: door.label, font: Name.face(.footnote, door == .link ? .semibold : .regular, at: size),
                         padding: CGSize(width: 22, height: 12))
                }
            case .library:
                return [
                    Name(text: localized("app.name"), font: .systemFont(ofSize: 34, weight: .bold), tracking: 6),
                    Name(text: localized("app.mark"), font: Name.face(.caption2, .medium, at: size), tracking: 3),
                ]
            case .about:
                return [
                    Name(text: localized("app.name"), font: Name.face(.title2, .bold, at: size)),
                    Name(text: localized("app.mark"), font: Name.face(.caption1, .medium, at: size), tracking: 2),
                ]
            case .game, .drill:
                // The bars are set no larger than the first accessibility size (`chromeType`).
                return [Name(text: Controller.engine.playerName,
                             font: Name.face(.caption1, .regular, at: min(size, .accessibility1)), byPrefix: true)]
            case .book, .editor, .collection:
                return []
            }
        }
    }

    /// A name the screen draws, which is never broken inside a word nor cut short: each word of it
    /// on one line, and as many lines as the words need. What it is drawn in is stated here, so it
    /// can be measured the way it is set; the accessibility tree hands back the whole text whether
    /// or not the screen showed all of it, and the frame it was given is what says which.
    struct Name {
        let text: String
        let font: UIFont
        var tracking: CGFloat = 0
        /// What the frame holds besides the text: a chip's padding.
        var padding = CGSize.zero
        /// Matched by its start rather than whole: the engine's bar names a rung after the engine.
        var byPrefix = false

        func matches(_ word: ScreenImage.Word) -> Bool {
            byPrefix ? word.text.hasPrefix(text) : word.text == text
        }

        /// Why `drawn` — this name as the screen said it, the rung and all — cannot be in `frame`
        /// whole, or nil when it can.
        func breach(of drawn: String, in frame: CGRect) -> String? {
            let width = frame.width - padding.width + 1
            func measure(_ part: String) -> CGFloat {
                (part as NSString).size(withAttributes: [.font: font, .kern: tracking]).width
            }
            var lines = 0
            var line: CGFloat = 0
            let space = measure(" ")
            for part in drawn.split(whereSeparator: \.isWhitespace) {
                let size = measure(String(part))
                if size > width {
                    return "is \(Int(frame.width)) pt wide, too narrow for 「\(part)」 (\(Int(size)) pt) on one line"
                }
                if lines == 0 || line + space + size > width {
                    lines += 1
                    line = size
                } else {
                    line += space + size
                }
            }
            let tall = CGFloat(lines) * font.lineHeight
            if tall > frame.height - padding.height + 1 {
                return "is \(Int(frame.height)) pt tall, short of the \(lines) line(s) its words need (\(Int(tall)) pt): cut off"
            }
            return nil
        }

        /// The system face for a text style at a text size, as SwiftUI sets it.
        static func face(_ style: UIFont.TextStyle, _ weight: UIFont.Weight, at size: DynamicTypeSize) -> UIFont {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
            let point = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
            return .systemFont(ofSize: point, weight: weight)
        }
    }

    nonisolated static var cases: [(Screen, Row)] {
        Screen.allCases.flatMap { screen in Row.all.map { (screen, $0) } }
    }

    @Test("every screen keeps its layout in each row", arguments: cases)
    func holdsItsLayout(_ screen: Screen, _ row: Row) async throws {
        let spoken = Speech.language
        Speech.language = row.language
        defer { Speech.language = spoken }
        let rendered = try await draw(screen, row)
        #expect(rendered.says(screen.ownWord), "\(screen) in \(row) does not say \(screen.ownWord)")
        for name in screen.names(at: row) {
            let drawn = rendered.elements.filter(name.matches)
            guard let first = drawn.min(by: { $0.frame.minY < $1.frame.minY }) else {
                Issue.record("\(screen) at \(row) does not draw the name 「\(name.text)」")
                continue
            }
            if let broken = name.breach(of: first.text, in: first.frame) {
                Issue.record("\(screen) at \(row): 「\(first.text)」 \(broken)")
            }
        }
        for breach in rendered.layoutBreaches() {
            if let known = Self.known(breach, on: screen, at: row, in: rendered) {
                withKnownIssue(known) { Issue.record("\(screen) at \(row): \(breach)") }
            } else {
                Issue.record("\(screen) at \(row): \(breach)")
            }
        }
    }

    /// The breaches this suite found in the app the day it was written, each filed as its own
    /// issue; nil for anything else, which fails. A breach that is fixed simply stops being
    /// recorded, and its line here goes with the fix.
    private static func known(
        _ breach: ScreenImage.Rendered.Breach, on screen: Screen, at row: Row, in rendered: ScreenImage.Rendered
    ) -> Comment? {
        // A navigation bar is the 54 pt under the top of the safe area.
        let inBar = breach.word.frame.maxY <= rendered.safeArea.minY + 54
        switch (breach.rule, screen) {
        case (.smallControl, .game), (.smallControl, .drill):
            return "chessmirror#26: the game screen's bar and record controls are under 44×44 pt"
        case (.smallControl, .importSheet) where !inBar:
            return "chessmirror#27: the import sheet's door buttons are 27 pt tall"
        case (.smallControl, .library):
            return "chessmirror#28: 拉新棋 and its hint line are under 44 pt tall"
        case (.smallControl, .importSheet), (.smallControl, .editor):
            return inBar ? "chessmirror#29: navigation bar text buttons report 36 pt tall" : nil
        case (.smallControl, .about):
            return inBar
                ? "chessmirror#29: navigation bar text buttons report 36 pt tall"
                : "chessmirror#31: About's List pickers report 34 pt tall"
        case (.overlap, .editor) where row == .accessibilityText:
            return "chessmirror#30: at accessibility text sizes the editor's hint overlaps its board"
        default:
            return nil
        }
    }

    // ------------------------------------------------------------------ the screens

    private func draw(_ screen: Screen, _ row: Row) async throws -> ScreenImage.Rendered {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-matrix-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "matrix-\(screen.rawValue)-\(row.testDescription)"

        func shoot(_ view: some View) async -> ScreenImage.Rendered {
            await ScreenImage.write(name, style: row.style, size: row.size) {
                view.dynamicTypeSize(row.typeSize)
            }
        }

        let library = try Self.library(in: directory)
        let shelf = CollectionShelf(library: library)
        let index = MistakeIndex(log: PracticeLog(url: directory.appending(path: "p.jsonl")))
        index.update(from: library.entries)
        let quiet = EngineHost(ScriptedEngine([]))

        switch screen {
        case .library:
            return await shoot(
                LibraryScreen(autoFetch: .quiet)
                    .environment(quiet).environment(library).environment(shelf).environment(index))
        case .book:
            return await shoot(
                NavigationStack { BookScreen(path: .constant([])) }
                    .environment(library).environment(shelf).environment(index).environment(quiet))
        case .about:
            return await shoot(
                AboutScreen().environment(quiet).environment(library).environment(shelf))
        case .game:
            let game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: Self.italian))
            let engine = ScriptedEngine([GameScreenScreenshots.opinion(.centipawns(30))], isEndless: true)
            let session = GameSession.fresh(game, controllers: [.white: .hand, .black: .engine], engine: engine)
            defer { session.suspend() }
            return await shoot(
                NavigationStack { GameScreen(session: session, path: .constant([])) }
                    .environment(EngineHost(engine)).environment(library).environment(shelf))
        case .drill:
            let game = try #require(Game(startFEN: "4kb1r/p2n1ppp/4q3/4p1B1/4P3/1Q6/PPP2PPP/2KR4 w - - 0 1"))
            let position = try #require(PositionKey(fen: game.state.fen))
            let log = PracticeLog(url: directory.appending(path: "drill.jsonl"))
            let drill = try #require(Drill(position: position, engine: ScriptedEngine([]), log: log))
            return await shoot(
                NavigationStack { DrillScreen(drill: drill, position: position, path: .constant([])) }
                    .environment(quiet).environment(library).environment(shelf)
                    .environment(MistakeIndex(log: log)))
        case .editor:
            let draft = try #require(PositionDraft(fen: PGN.standardStartFEN))
            return await shoot(
                NavigationStack {
                    ConfirmPositionScreen(proposal: PositionProposal(draft: draft), path: .constant([]))
                }
                .environment(quiet).environment(library).environment(shelf))
        case .collection:
            let game = try #require(library.entries.first?.pgn?.game.rewound(to: 4))
            let position = try #require(PositionKey(fen: game.state.fen))
            #expect(shelf.add(position, to: PlayerCollection.favouritesName,
                              game: library.entries.first?.url, ply: 4))
            return await shoot(
                NavigationStack { CollectionScreen(kind: .favourites, path: .constant([])) }
                    .environment(quiet).environment(library).environment(shelf).environment(index))
        case .importSheet:
            return await shoot(
                ImportSheet(memory: PlayerSettings(store: InMemorySettings()).imports, initialDoor: .link)
                    .environment(library).environment(shelf).environment(index))
        }
    }

    private static let italian = ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6"]

    /// One game, reviewed, with a mistake in it — so 首页 has a row, 错题本 a page and a set a
    /// position — named by the player rather than by a language.
    private static func library(in directory: URL) throws -> GameLibrary {
        var game = try #require(Game(
            startFEN: PGN.standardStartFEN,
            uciMoves: ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6"]
        ))
        game.applyReview(
            Array(repeating: Score.centipawns(30), count: 5) + [.mate(in: 1)],
            startEvaluation: .centipawns(20), depth: 16
        )
        let pgn = PGN(game: game, tags: [
            PGN.Tag("White", Controller.hand.playerName),
            PGN.Tag("Black", Controller.hand.playerName),
            PGN.Tag(GameLibrary.nameTag, "Wednesday"),
        ])
        try pgn.text.write(to: directory.appending(path: "scholar.pgn"), atomically: true, encoding: .utf8)
        return GameLibrary(folder: GameFolder(url: directory))
    }
}

import ChessmirrorKit
import ChessmirrorKitTesting
import Foundation
import Testing

/// 收藏集: the 自动集 the games fill, the 自建集 the player fills, and the 日课 they share
/// (docs/adr/0051).

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let day = 86_400.0

/// A saved game with a Score on every position, both sides moved by hand.
@MainActor
private func reviewed(
    _ ucis: [String], scores: [Score], named name: String = "g", at when: Date = now
) throws -> GameLibrary.Entry {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: ucis))
    game.applyReview(scores, startEvaluation: .centipawns(20), depth: 16)
    let pgn = PGN(
        game: game,
        tags: [
            PGN.Tag("White", Controller.hand.playerName),
            PGN.Tag("Black", Controller.hand.playerName),
        ]
    )
    return GameLibrary.Entry(url: URL(filePath: "/games/\(name).pgn"), pgn: pgn, modified: when)
}

/// 1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6?? — and Qxf7 is mate.
private let scholar = ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6"]
/// 1. e4 e5 2. Nf3 Nc6 3. Bc4 and then Black's third move.
private func italian(_ third: String) -> [String] {
    ["e2e4", "e7e5", "g1f3", "b8c6", "f1c4", third]
}
private let level: [Score] = Array(repeating: .centipawns(30), count: 5)

private func temporaryLog() -> PracticeLog {
    PracticeLog(
        url: URL(filePath: NSTemporaryDirectory())
            .appending(path: "chessmirror-collections-\(UUID().uuidString).jsonl")
    )
}

@MainActor
private func temporaryFolder() -> GameFolder {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return GameFolder(url: url)
}

// ------------------------------------------------------------------- 自动集

@MainActor
@Test("a mate the opponent's move allowed is a 杀招, seen from the side that can give it")
func aMateAllowedIsFound() throws {
    let entry = try reviewed(scholar, scores: level + [.mate(in: 1)])
    let shots = FoundShots.sightings(in: entry)
    #expect(shots.count == 1)
    let shot = try #require(shots.first)
    #expect(shot.card == .mate)
    #expect(shot.sighting.ply == 6)
    #expect(shot.position.sideToMove == .white, "the side to move is the side with the shot")
    #expect(shot.sighting.isYours == true)
}

@MainActor
@Test("a mating attack is one 杀招, where the mate first appeared, and a long mate is none")
func aMateIsFoundOnceAndOnlyWhenShort() throws {
    // The mate was already on the board before Black's move: nothing new appeared.
    let already = try reviewed(
        scholar, scores: Array(level.prefix(4)) + [.mate(in: 2), .mate(in: 1)]
    )
    #expect(FoundShots.sightings(in: already).isEmpty)
    let far = try reviewed(scholar, scores: level + [.mate(in: FoundShots.mateWithin + 1)])
    #expect(FoundShots.sightings(in: far).isEmpty, "past the limit it is a calculation")
}

@MainActor
@Test("a gift that leaves the side to move well placed is a 战术 — unless it is just a free piece")
func aTacticIsAGiftThatIsNotAFreePiece() throws {
    // 3…Nf6: nothing to take for free, and White stands at +2.5.
    let shot = try reviewed(italian("g8f6"), scores: level + [.centipawns(250)])
    #expect(FoundShots.sightings(in: shot).map(\.card) == [.tactics])
    // 3…Nd4 leaves e5 hanging: Nxe5 wins a pawn by exchange, and that is 「白吃」.
    let free = try reviewed(italian("c6d4"), scores: level + [.centipawns(250)])
    #expect(FoundShots.sightings(in: free).isEmpty)
    // The same gift that only brings White level is not a shot for White.
    let small = try reviewed(italian("g8f6"), scores: level.dropLast() + [.centipawns(-250), .centipawns(0)])
    #expect(!FoundShots.sightings(in: small).contains { $0.sighting.ply == 6 })
}

@MainActor
@Test("an unreviewed game is read by the judgements written as its moves landed")
func judgementsAreEnough() throws {
    var game = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: scholar))
    for ply in 0..<5 {
        game.setJudgement(.init(drop: 0, score: .centipawns(30), depth: 12), atPly: ply)
    }
    game.setJudgement(.init(drop: 60, score: .mate(in: 1), depth: 12), atPly: 5)
    let entry = GameLibrary.Entry(
        url: URL(filePath: "/games/played.pgn"), pgn: PGN(game: game), modified: now
    )
    #expect(FoundShots.sightings(in: entry).map(\.card) == [.mate])
    // A game nobody measured is in neither set.
    let bare = try #require(Game(startFEN: PGN.standardStartFEN, uciMoves: scholar))
    let unmeasured = GameLibrary.Entry(
        url: URL(filePath: "/games/bare.pgn"), pgn: PGN(game: bare), modified: now
    )
    #expect(FoundShots.sightings(in: unmeasured).isEmpty)
}

@MainActor
@Test("the same shot in two games is one 藏局 with two sightings, and taken out is gone")
func foundSetsMergeByPosition() throws {
    let one = try reviewed(scholar, scores: level + [.mate(in: 1)], named: "one", at: now - day)
    let two = try reviewed(scholar, scores: level + [.mate(in: 1)], named: "two", at: now)
    let shots = FoundShots.sightings(in: one) + FoundShots.sightings(in: two)
    let sets = FoundShots.collections(of: shots)
    #expect(sets.map(\.kind) == [.found(.mate), .found(.tactics)])
    let mates = try #require(sets.first)
    #expect(mates.holdings.count == 1)
    #expect(mates.holdings[0].sightings.map(\.game.lastPathComponent) == ["two.pgn", "one.pgn"])
    let taken = FoundShots.collections(of: shots, takenOut: [mates.holdings[0].position])
    #expect(taken[0].holdings.isEmpty)
}

// ------------------------------------------------------------------- 自建集

@Test("a 自建集 is a PGN of moveless games, one per position, and reads back whole")
func aPlayerCollectionRoundTrips() throws {
    let key = try #require(PositionKey(fen: "r1bqkb1r/pppp1Qpp/2n2n2/4p3/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 0 4"))
    let other = try #require(PositionKey(fen: PGN.standardStartFEN))
    let set = PlayerCollection(
        name: "开局 \"陷阱\"",
        entries: [
            .init(position: key, added: now, game: "chessmirror-1.pgn", ply: 7),
            .init(position: other, added: now + 60),
        ]
    )
    let text = set.pgnText
    #expect(text.contains("[SetUp \"1\"]"))
    #expect(text.contains("[FEN \"\(key.text) 0 1\"]"))
    let read = PlayerCollection(name: set.name, pgnText: text)
    #expect(read == set)
    // And a position is a game any PGN reader can open.
    let first = try PGN(parsing: String(text.split(separator: "\n\n[").first ?? ""))
    #expect(PositionKey(fen: first.game.startFEN) == key)
}

@MainActor
@Test("喜爱 is always there and cannot be renamed or deleted; other sets can")
func favouritesIsFixed() throws {
    let shelf = CollectionShelf(folder: temporaryFolder())
    #expect(shelf.names == [PlayerCollection.favouritesName])
    #expect(!shelf.rename(PlayerCollection.favouritesName, to: "x"))
    #expect(!shelf.delete(PlayerCollection.favouritesName))
    #expect(!shelf.create(PlayerCollection.favouritesName), "its file name is not free")
    #expect(!shelf.create("  "))
    #expect(!shelf.create("a/b"))

    #expect(shelf.create("残局"))
    #expect(!shelf.create("残局"), "a name is one set")
    #expect(shelf.rename("残局", to: "车兵残局"))
    #expect(shelf.names == [PlayerCollection.favouritesName, "车兵残局"])
    #expect(shelf.delete("车兵残局"))
    #expect(shelf.names == [PlayerCollection.favouritesName])
}

@MainActor
@Test("a position can be in several sets, and the sets are files that outlive the shelf")
func positionsLiveInSeveralSetsOnDisk() throws {
    let folder = temporaryFolder()
    let shelf = CollectionShelf(folder: folder)
    let key = try #require(PositionKey(fen: PGN.standardStartFEN))
    #expect(!shelf.isKept(key))
    let game = folder.url.appending(path: "chessmirror-x.pgn")
    #expect(shelf.add(key, to: PlayerCollection.favouritesName, game: game, ply: 3, now: now))
    #expect(!shelf.add(key, to: PlayerCollection.favouritesName), "once per set")
    #expect(shelf.create("开局"))
    #expect(shelf.add(key, to: "开局", now: now + 1))
    #expect(shelf.names(holding: key) == [PlayerCollection.favouritesName, "开局"])

    let again = CollectionShelf(folder: folder)
    #expect(again.names(holding: key) == [PlayerCollection.favouritesName, "开局"])
    let entry = try #require(again.collection(named: PlayerCollection.favouritesName)?.entries.first)
    #expect(entry.game == "chessmirror-x.pgn")
    #expect(entry.ply == 3)
    #expect(again.remove(key, from: "开局"))
    #expect(again.names(holding: key) == [PlayerCollection.favouritesName])

    // The library lists the games and never a set.
    let library = GameLibrary(folder: folder)
    #expect(library.entries.isEmpty)
}

// ------------------------------------------------------------------- 日课

private func holding(_ n: Int, added: Date = now) -> Holding {
    let key = PositionKey("8/8/8/8/8/8/\(n)/K6k w - -")
    return Holding(
        position: key, sightings: [Sighting(game: URL(filePath: "/g/\(n).pgn"), ply: n, when: added)],
        added: added
    )
}

private func mistake(_ n: Int) -> Mistake {
    let key = PositionKey("8/8/8/8/8/8/\(n)/k6K b - -")
    return Mistake(
        position: key,
        encounters: [
            Encounter(
                game: URL(filePath: "/m/\(n).pgn"), ply: n, when: now, played: "Kb1", wanted: nil,
                cost: 40, origin: .fresh
            )
        ]
    )
}

@Test("found 藏局 join the 日课 with a daily intake of their own, taking turns with the 错题")
func foundHoldingsJoinTheDaily() {
    let book = MistakeBook(mistakes: (1...3).map(mistake))
    let found = (1...8).map { holding($0, added: now - Double($0) * 60) }
    let daily = Daily.forToday(book: book, attempts: [], found: found, now: now)
    #expect(daily.cards.count == 3 + Daily.foundPerDay, "five found, however many are waiting")
    let kinds = daily.cards.map { $0.mistake != nil }
    #expect(Array(kinds.prefix(6)) == [true, false, true, false, true, false], "never a block")
    #expect(daily.cards.compactMap(\.holding).first?.position == found[0].position,
            "the most recently found first")
    #expect(daily.all.count == 3 + 8)
}

@Test("a position that is an owed 错题 is scheduled as that, once")
func aMistakeIsScheduledOnce() {
    let one = mistake(1)
    let same = Holding(position: one.position, sightings: [], added: now)
    let daily = Daily.forToday(book: MistakeBook(mistakes: [one]), attempts: [], found: [same], now: now)
    #expect(daily.cards.count == 1)
    #expect(daily.cards[0].mistake == one)
}

@Test("a 计划外 go at a 藏局 moves nothing; a 日课 go does")
func onlyTheDailyMovesAHolding() {
    let found = [holding(1)]
    func go(_ source: Drill.Source) -> [(at: Date, attempt: PracticeLog.Attempt)] {
        [(now - 3600, PracticeLog.Attempt(
            position: found[0].position, seconds: 5, passed: true, played: "Kb1", cost: 0,
            hints: 0, source: source
        ))]
    }
    let picked = Daily.forToday(book: MistakeBook(mistakes: []), attempts: go(.picked), found: found, now: now)
    #expect(picked.cards.first?.isNew == true)
    let daily = Daily.forToday(book: MistakeBook(mistakes: []), attempts: go(.daily), found: found, now: now)
    #expect(daily.all.first?.isNew == false)
    #expect(daily.cards.isEmpty, "held today, due another day")
}

@Test("the 日课 door reads 「今天的练完了」 rather than 「还没有错题」 when only 藏局 were due")
func theDoorKnowsAboutHoldings() {
    let daily = Daily(cards: [], all: [
        Daily.Card(holding: holding(1), memory: nil, dueAt: nil, lapses: 0)
    ])
    let door = PracticeDay(daily: daily, book: MistakeBook(mistakes: [])).door
    #expect(door.label == localized("daily.done"))
}

// ------------------------------------------------------------------- the index

@MainActor
@Test("the index keeps the 自动集 beside the book, and a 藏局 taken out stays out")
func theIndexKeepsTheFoundSets() throws {
    let log = temporaryLog()
    let index = MistakeIndex(log: log)
    let entry = try reviewed(scholar, scores: level + [.mate(in: 1)])
    let tactic = try reviewed(italian("g8f6"), scores: level + [.centipawns(250)], named: "t")
    index.update(from: [entry, tactic])
    #expect(index.found.map(\.holdings.count) == [1, 1])
    // Black's two blunders are 错题 of their own — the positions *before* them — and the shots
    // they left are the positions after: four cards, two of each, taking turns.
    #expect(index.daily.cards.map { $0.holding != nil } == [false, true, false, true])

    let mate = try #require(index.found.first?.holdings.first?.position)
    index.takeOut(mate)
    #expect(index.found.map(\.holdings.count) == [0, 1])
    #expect(!index.daily.cards.contains { $0.position == mate })

    let reopened = MistakeIndex(log: log)
    reopened.update(from: [entry, tactic])
    #expect(reopened.found.map(\.holdings.count) == [0, 1], "the log remembers")
    #expect(reopened.book.mistakes.count == 2, "taking out is not striking off")
    #expect(PracticeLog.dismissed(in: log.entries()).isEmpty)
}

@MainActor
@Test("a drill of a 藏局 from the 日课 writes a scheduled go under its position")
func aHoldingIsDrilledLikeAMistake() throws {
    let log = temporaryLog()
    let index = MistakeIndex(log: log)
    let entry = try reviewed(scholar, scores: level + [.mate(in: 1)])
    index.update(from: [entry])
    let card = try #require(index.daily.cards.first { $0.holding != nil })
    let drill = try #require(index.practise(card.position, engine: nil, source: .daily))
    #expect(drill.lines.noSlips, "under 把关, as every 练习 is")
    #expect(drill.mover == .white, "seen from the side with the shot")
    let next = try #require(index.practiceDay.next(after: card.position))
    #expect(next != card.position)
    #expect(index.book[next] != nil, "and the 错题 Black made to allow it comes next")
}

import Foundation

/// 门 — the import sheet's four ways in, what has been typed at each, and what the sheet says
/// about it (CONTEXT.md, docs/adr/0014, docs/adr/0045).
///
/// Two doors take a username — lichess and chess.com — and fetch that player's last few games;
/// one takes a 国象联盟 share link, which carries its game with it; and one takes any other link.
/// Four doors and one pipeline behind them (`ImportSession`): this is the doors. It was the
/// sheet's own state for a year — which door opens, whose name is in the field, what the button
/// says, when a name is remembered — so every one of those answers was a screenshot away.
///
/// It remembers (`ImportMemory`): the account that fetched last is in the field when its door
/// opens, the other accounts that have fetched are a chip away, and the door and count are the
/// ones used last time. The button says what it is about to do — 「拉 sunfmin 最近 10 局」 — so a
/// wrong name is caught before the network is asked.
@MainActor @Observable public final class ImportDoors {
    /// Which door. Not a mode — all four share every state after the download, because after
    /// the download there is no difference between them.
    public enum Door: String, Hashable, CaseIterable, Sendable {
        case lichess
        case chessCom
        case chessease
        case link

        /// The site a door belongs to; the plain link door belongs to none.
        public var site: PGNImport.Site? {
            switch self {
            case .lichess: .lichess
            case .chessCom: .chessCom
            case .chessease: .chessease
            case .link: nil
            }
        }

        /// A door that asks for a username rather than a link.
        public var asksForPlayer: Bool {
            site.map { PGNImport.Site.withPlayers.contains($0) } ?? false
        }

        public var label: String { site?.label ?? localized("import.door.link") }

        public var explainer: String {
            switch self {
            case .lichess: localized("import.door.lichess.explained")
            case .chessCom: localized("import.door.chessCom.explained")
            case .chessease: localized("import.door.chessease.explained")
            case .link: localized("import.door.link.explained")
            }
        }

        /// What the field says while it is empty.
        public var prompt: String {
            switch self {
            case .lichess: localized("import.field.player", PGNImport.Site.lichess.label)
            case .chessCom: localized("import.field.player", PGNImport.Site.chessCom.label)
            case .chessease: localized("import.field.share")
            case .link: localized("import.field.link")
            }
        }
    }

    public let session: ImportSession
    public let memory: ImportMemory

    /// The door open now.
    public private(set) var door: Door
    /// How many recent games a player's door asks for.
    public private(set) var count: Int
    /// One field's text per door, so switching doors and back loses nothing typed.
    private var typed: [Door: String]

    /// How many recent games may be asked for. Fixed steps rather than a number to type: the
    /// useful answers are "the last few" and "enough for a flight", and neither is a number
    /// anyone has in mind.
    public static let counts = [5, 10, 20, 50]

    /// - Parameters:
    ///   - initialInput: a link handed in from outside — the share extension — which opens the
    ///     door it belongs to with the link already in the field.
    ///   - initialDoor: the door to open, when not the one used last.
    public init(
        session: ImportSession = ImportSession(), memory: ImportMemory,
        initialInput: String = "", initialDoor: Door? = nil
    ) {
        self.session = session
        self.memory = memory
        var typed: [Door: String] = [:]
        for site in PGNImport.Site.withPlayers {
            if let name = memory.latest(on: site), let door = Door(rawValue: site.rawValue) {
                typed[door] = name
            }
        }
        var door = initialDoor ?? Door(rawValue: memory.door) ?? .lichess
        if !initialInput.isEmpty {
            door = PGNImport.chesseaseGame(in: initialInput) != nil ? .chessease : .link
            typed[door] = initialInput
        }
        self.typed = typed
        self.door = door
        count = memory.count
    }

    // ------------------------------------------------------------------ the field

    /// The field's text at the door open now, as typed.
    public var text: String {
        get { typed[door] ?? "" }
        set { typed[door] = newValue }
    }

    /// What will be sent: the text, without the spaces a paste brings.
    public var input: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The account a player's door is about, once one is typed — whose side every game it
    /// fetches is kept for. Nil through a link, where nobody is known.
    public var account: String? { door.asksForPlayer && !input.isEmpty ? input : nil }

    /// The accounts that have fetched through this door before, newest first.
    public var remembered: [String] { door.site.flatMap { memory.names[$0] } ?? [] }

    /// Whether the failure on show is about what was typed here — a name the site does not know,
    /// a link that is not one — so the field it came from is marked.
    public var isInputAtFault: Bool {
        if case .failed(let error) = session.phase { error.isAboutInput } else { false }
    }

    // ------------------------------------------------------------------ pressing

    /// Another door: whatever the last one fetched is put away, and the door is remembered.
    public func open(_ door: Door) {
        self.door = door
        memory.door = door.rawValue
        session.reset()
    }

    /// Another count, remembered for next time.
    public func ask(for count: Int) {
        self.count = count
        memory.count = count
    }

    /// A remembered account's chip: its name in the field.
    public func pick(_ account: String) {
        typed[door] = account
        session.reset()
    }

    /// A remembered account struck off its chip.
    public func forget(_ account: String) {
        guard let site = door.site else { return }
        memory.forget(account, on: site)
    }

    /// The field emptied.
    public func clear() {
        typed[door] = ""
        session.reset()
    }

    /// 「再来」: back to asking. A player's door keeps the name — the next fetch is most likely
    /// the same account — and a link door empties, because a link is used once.
    public func again() {
        session.reset()
        if !door.asksForPlayer { typed[door] = "" }
    }

    public var canFetch: Bool { !input.isEmpty }

    /// What the button will do, said with the name and the number it will do it with — the
    /// sentence is the check that the right account is about to be asked.
    public var fetchLabel: String {
        switch door {
        case .lichess, .chessCom:
            input.isEmpty
                ? localized("import.fetch") : localized("import.fetch.recent", plural: count, input)
        case .chessease: localized("import.fetch.share")
        case .link: localized("import.fetch")
        }
    }

    /// What the button under a failure says: the fetch again, with its name, when what is wanted
    /// is a corrected input; a bare 重试 when the network or the site let it down.
    public var retryLabel: String {
        isInputAtFault ? fetchLabel : localized("retry")
    }

    /// Fetches through the door open now. A name is remembered the moment it has fetched
    /// something, and not before: a misspelling that failed is not an account.
    public func fetch() async {
        guard canFetch else { return }
        let input = input
        if door.asksForPlayer, let site = door.site {
            await session.recent(of: input, count: count, on: site)
            if case .ready = session.phase { memory.remember(input, on: site) }
        } else {
            await session.run(input)
        }
    }

    // ------------------------------------------------------------------ what came down

    /// What the download found, as the sheet says it: how many games, what a tap on one does,
    /// the one press that writes them, and — once pressed — what it did.
    public struct Reading: Equatable, Sendable {
        /// 「8 局」
        public let summary: String
        /// What opening a row will do: keep the account's side, or ask whose.
        public let tapHint: String
        /// The press that writes the games — 「入库 8 局（2 局已有）」 — while there is any to add.
        public let apply: String?
        /// What the press did, once there is nothing left to add.
        public let applied: String?
    }

    /// The plan read against the library and the 错题本 it would be written into.
    public func reading(
        _ plan: PGNImport.ImportPlan, in library: GameLibrary, book: MistakeIndex, hasEngine: Bool
    ) -> Reading {
        let standing = plan.chapters.map { session.status(of: $0, in: library, book: book) }
        let toAdd = standing.count { $0 == .notImported }
        var applied: String?
        var apply: String?
        if let outcome = session.applied, toAdd == 0 {
            let scoring = standing.contains { if case .scoring = $0 { true } else { false } }
            applied = outcome.imported == 0
                ? localized("import.applied.none")
                : !hasEngine
                    ? localized("import.done", plural: outcome.imported)
                    : scoring
                        ? localized("import.applied", plural: outcome.imported)
                        : localized("import.applied.landed", plural: outcome.imported)
        } else if toAdd > 0 {
            var label = localized("import.apply", plural: toAdd)
            if plan.chapters.count > toAdd {
                label += " " + localized("import.apply.skipped", plural: plan.chapters.count - toAdd)
            }
            apply = label
        }
        return Reading(
            summary: localized("import.plan.games", plural: plan.chapters.count),
            tapHint: account.map { localized("import.plan.tap.player", $0) }
                ?? localized("import.plan.tap.link"),
            apply: apply,
            applied: applied
        )
    }

    /// One game in the list, as the account would tell it — which colour they had, who they
    /// played, how it went, when — or, through a link, the chapter's own name.
    public struct Row: Equatable, Sendable {
        /// The account's colour in it; nil through a link, where opening it asks whose.
        public let side: PieceColour?
        /// The opponent, or the chapter's name.
        public let title: String
        public let verdict: String?
        public let when: String?
        /// The 错题本's standing on the game.
        public let status: String

        /// Everything the row says, in the order it says it.
        public var spoken: String {
            [side.map(\.label), title, verdict, when].compactMap { $0 }.joined(separator: " · ")
        }
    }

    public func row(
        _ chapter: PGNImport.ImportChapter, in library: GameLibrary, book: MistakeIndex
    ) -> Row {
        let side = account.flatMap { PGNImport.side(of: $0, in: chapter.pgn) }
        return Row(
            side: side,
            title: side.map { chapter.pgn.playerName($0.opposite) ?? "?" } ?? chapter.name,
            verdict: side.flatMap { PGNImport.verdict(for: $0, in: chapter.pgn) },
            when: side != nil ? PGNImport.playedAt(chapter.pgn) : nil,
            status: session.status(of: chapter, in: library, book: book).label
        )
    }
}

extension PGNImport.Error {
    /// A failure the typed text is answerable for — as against one the network or the site is.
    /// The sheet marks the field for these, and offers the fetch again rather than a bare retry,
    /// because what is wanted is a corrected input and not the same one a second time.
    public var isAboutInput: Bool {
        switch self {
        case .notALink, .unknownPlayer, .notAPlayer, .noGames, .unreadableShare, .missingGame: true
        default: false
        }
    }
}

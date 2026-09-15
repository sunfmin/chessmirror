import ChessfenKit
import SwiftUI

/// One 错题, being practised (docs/adr/0029).
///
/// **Nothing is said before the move.** The position goes up and it is your turn; there is no
/// theme, no "white to play and win", no piece ringed. A screen that says what to look for has
/// answered the question it was asking — the whole thing being trained here is noticing, and a
/// tactic announced is a tactic already half solved.
///
/// After the move, everything is said at once: what the move was for, what it cost, and, when it
/// failed, what to have played instead. Retrieval practice without corrective feedback is worth
/// nothing measurable (Rowland 2014), so the pass is told what it did as fully as the failure.
struct DrillScreen: View {
    let drill: Drill
    /// The 错题 this came off, for the two exits that need to know where it sits in the book.
    let mistake: Mistake
    /// Whether this came out of the day's queue or off the book. 下一题 means a different
    /// thing either way — the queue's next, or the next one down the book.
    var source: Drill.Source = .picked
    @Binding var path: [Step]

    @Environment(EngineHost.self) private var engine
    @Environment(GameLibrary.self) private var library
    @Environment(MistakeIndex.self) private var index

    @State private var selected: Square?
    @State private var promotion: GameScreen.PromotionRequest?

    private var viewed: Game { drill.game }

    private var candidateMoves: [Move] {
        guard let selected, !drill.isSettled, !drill.isJudging else { return [] }
        return viewed.state.moves(from: selected)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                board
                Group {
                if drill.isSettled || drill.isJudging {
                    settlement
                } else {
                    Text(localized("drill.prompt"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
        .background(Palette.parchment)
        .navigationTitle(localized("drill"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.parchment, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // The attempt is a new line in the log, and the day is a function of the log: the count
        // on the first screen has to have heard about it before anybody goes back there.
        .onChange(of: drill.isSettled) { _, settled in
            if settled { index.refresh() }
        }
        .confirmationDialog(
            localized("game.promotion"), isPresented: .constant(promotion != nil),
            titleVisibility: .visible
        ) {
            ForEach(promotion?.moves ?? [], id: \.uci) { move in
                Button(move.promotion?.label ?? move.uci) {
                    drill.play(move)
                    promotion = nil
                }
            }
            Button(localized("cancel"), role: .cancel) { promotion = nil }
        }
    }

    // ------------------------------------------------------------------ parts

    /// From the side that has to find the move, and drawn without the engine's arrow: the
    /// recommendation is the answer, and it arrives when the move has been played.
    private var board: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                BoardView(
                    pieces: BoardRenderer.placement(viewed.state.fen) ?? [:],
                    orientation: drill.mover == .white ? .whiteAtBottom : .blackAtBottom,
                    lastMove: lastMove,
                    checks: viewed.state.checkSquares,
                    selected: selected,
                    destinations: Set(candidateMoves.map(\.to)),
                    captures: Set(candidateMoves.filter(\.isCapture).map(\.to)),
                    isInteractive: !drill.isSettled && !drill.isJudging,
                    onTap: tap
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var lastMove: MoveSquares? {
        viewed.plies.last.flatMap { MoveSquares(uci: $0.uci) }
    }

    @ViewBuilder private var settlement: some View {
        if drill.isJudging {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(localized("drill.judging")).font(.footnote).foregroundStyle(Palette.inkSoft)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else if let verdict = drill.verdict {
            VStack(alignment: .leading, spacing: 12) {
                Text(verdict.sentence)
                    .font(.subheadline)
                    .foregroundStyle(verdict.passed ? Palette.analysis : Palette.ink)
                if let seconds = drill.seconds {
                    Text(localized("drill.seconds", plural: Int(seconds.rounded())))
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                }
                exits
            }
            .padding(14)
            .background(
                (verdict.passed ? Palette.analysis : Palette.alarm).opacity(0.10),
                in: RoundedRectangle(cornerRadius: 14)
            )
        } else {
            Text(localized("drill.noEngine"))
                .font(.footnote)
                .foregroundStyle(Palette.alarm)
        }
    }

    /// The three ways out, and all three are always there. A drill that only offers 下一题 is a
    /// drill that has decided the position is finished with, and the whole reason somebody got it
    /// wrong may be that they do not know what happens next.
    private var exits: some View {
        VStack(spacing: 8) {
            exit(localized("drill.keepPlaying"), "play.fill", filled: true) { keepPlaying() }
            HStack(spacing: 8) {
                exit(localized("drill.leave"), "xmark") { path.removeAll() }
                if next != nil {
                    exit(localized("drill.next"), "arrow.right") { goToNext() }
                }
            }
        }
    }

    private func exit(
        _ title: String, _ symbol: String, filled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.footnote)
                Text(title).font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(filled ? Palette.parchment : Palette.ink)
            .padding(.vertical, 12)
            .background(
                filled ? Palette.ink : Palette.chipRest, in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
    }

    // ------------------------------------------------------------------ doing

    private func tap(_ square: Square) {
        guard !drill.isSettled, !drill.isJudging else { return }
        if let selected {
            let moves = viewed.state.moves(from: selected).filter { $0.to == square }
            if moves.count > 1 {
                promotion = GameScreen.PromotionRequest(moves: moves)
                self.selected = nil
                return
            }
            if let move = moves.first {
                drill.play(move)
                self.selected = nil
                return
            }
        }
        let pieces = BoardRenderer.placement(viewed.state.fen) ?? [:]
        selected = pieces[square]?.colour == viewed.state.sideToMove ? square : nil
    }

    /// 继续下: the position as a game, from where the attempt left it, with the engine answering.
    /// The move that was just played stays on the board — playing on from a mistake is how a
    /// person finds out what was actually wrong with it.
    private func keepPlaying() {
        // `playing` seats the engine opposite whoever is to move in the game it is handed, and
        // the attempt has already been played — so the side that answers is the right one.
        let session = GameSession.playing(drill.game, engine: engine.service, library: library)
        path.append(.game(session))
    }

    /// 下一题: the next item in the book, in the book's own order, put in this one's place so the
    /// back button still goes back to the list rather than through every drill of the session.
    private func goToNext() {
        guard let next, !path.isEmpty else { return }
        path[path.count - 1] = .drill(next, source)
    }

    /// 下一题: for a 日课 drill, whatever the schedule puts next — never a choice, and never a
    /// list to choose from (docs/adr/0032). For one picked off the book, the next one down it.
    ///
    /// This position is excluded either way: a card just failed is due again in hours rather than
    /// days, and asking it again immediately would only be asking somebody to repeat the move
    /// they were just shown.
    private var next: Mistake? {
        switch source {
        case .daily:
            return index.daily.cards.first { $0.position != mistake.position }?.mistake
        case .picked:
            let book = index.book.mistakes
            guard let here = book.firstIndex(where: { $0.position == mistake.position }),
                book.count > 1
            else { return nil }
            return book[(here + 1) % book.count]
        }
    }
}

/// Holds one `Drill` for as long as its screen is on the stack.
///
/// A drill is a live object with a clock running in it, so it cannot be built inside a
/// `navigationDestination` closure — that closure runs again every time the screen redraws, and a
/// fresh drill each time would reset the question the moment it was answered.
struct DrillHost: View {
    let mistake: Mistake
    let source: Drill.Source
    @Binding var path: [Step]
    @State private var drill: Drill?

    init(
        mistake: Mistake,
        engine: (any Engine)?,
        lines: JudgementLines,
        log: PracticeLog,
        source: Drill.Source = .picked,
        path: Binding<[Step]>
    ) {
        self.mistake = mistake
        self.source = source
        _path = path
        _drill = State(
            initialValue: Drill(
                position: mistake.position, engine: engine, log: log, lines: lines, source: source
            )
        )
    }

    var body: some View {
        if let drill {
            DrillScreen(drill: drill, mistake: mistake, source: source, path: $path)
        } else {
            // A 错题 whose position will not parse. Nothing to practise and nothing to say about
            // it that is not a lie about the board.
            Text(localized("book.empty"))
                .font(.footnote)
                .foregroundStyle(Palette.inkSoft)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.parchment)
        }
    }
}

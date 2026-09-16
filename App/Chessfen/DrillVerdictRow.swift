import ChessfenKit
import SwiftUI

/// 判决 — what came of one attempt at one 错题, as one row under the board (docs/adr/0029).
///
/// **One thing, said in colour.** A drill asks one question and this answers it: 过了 or 没过. The
/// word is the biggest thing in the row and the row is tinted, railed and written in the colour
/// that word means — teal for a move that held, alarm for one that gave something away — so the
/// answer arrives before anybody reads a sentence. Everything else in the row is subordinate to it:
/// the explanation is a footnote, and it is only there when the move failed, because 「你走对了，
/// 这是为什么」 is a paragraph nobody asked for.
///
/// **One button, and it moves you on.** 退出 was a second control competing with 下一题 for a row
/// this small, and it is what the navigation bar's back button already does. So there is one action
/// here, it is the one a person practising wants, and it is a full-width target rather than two
/// words of caption text: a drill is answered with a thumb.
///
/// It is the record row's cousin in shape — full width, square corners, a rail down the leading
/// edge, a hairline at each end — because it is a row of the same page. What is new is that the
/// rail's colour is a *verdict* rather than a category, which is the one thing this row has to say.
struct DrillVerdictRow: View {
    let drill: Drill
    /// The next question, when the queue has one. Nil is the end of the queue, and then the one
    /// button leaves instead of pretending there is somewhere to go.
    let next: (() -> Void)?
    let leave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headline
            if let explanation {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if drill.isSettled || drill.couldNotJudge { action }
        }
        .padding(.leading, 13)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.06))
        .overlay(alignment: .leading) { Rectangle().fill(tone).frame(width: 3) }
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
        .animation(.snappy(duration: 0.22), value: drill.isSettled)
    }

    /// The answer, or the question while there is not one yet.
    private var headline: some View {
        HStack(spacing: 8) {
            if drill.isJudging { ProgressView().controlSize(.small) }
            Text(word)
                .font(isAnswered ? .title3.weight(.semibold) : .subheadline)
                .foregroundStyle(isAnswered || drill.couldNotJudge ? tone : Palette.inkSoft)
            Spacer(minLength: 0)
        }
    }

    /// 下一题, and 退出 only when there is no next one — a button that leads nowhere is worse than
    /// a button that admits the queue is done.
    private var action: some View {
        Button {
            if let next { next() } else { leave() }
        } label: {
            HStack(spacing: 8) {
                Text(localized(next == nil ? "drill.leave" : "drill.next"))
                    .font(.subheadline.weight(.semibold))
                Image(systemName: next == nil ? "xmark" : "arrow.right")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Palette.parchment)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Whether the attempt has been judged, which is when this row has an answer to give.
    private var isAnswered: Bool { drill.verdict != nil }

    private var word: String {
        if let verdict = drill.verdict {
            return localized(verdict.passed ? "drill.held" : "drill.dropped")
        }
        if drill.couldNotJudge { return localized("drill.noEngine") }
        return localized(drill.isJudging ? "drill.judging" : "drill.prompt")
    }

    /// Why, and only when the answer was no. A move that held has been told that it held; a
    /// paragraph explaining a right answer is the app arguing with it (docs/adr/0027).
    private var explanation: String? {
        guard let verdict = drill.verdict, !verdict.passed else { return nil }
        return verdict.sentence
    }

    private var tone: Color {
        guard let verdict = drill.verdict else {
            return drill.couldNotJudge ? Palette.alarm : Palette.analysis
        }
        return verdict.passed ? Palette.analysis : Palette.alarm
    }
}

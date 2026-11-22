import SwiftUI
import Testing
import UIKit

/// The harness held to what makes it worth trusting: a screen it cannot hear fails, and the words
/// it hands back say where they were drawn.
@MainActor
@Suite(.serialized)
struct ScreenImageTests {
    /// With nothing listening SwiftUI builds no accessibility tree, and a harness that handed back
    /// that silence would pass every `#expect(!rendered.says(…))` in the suite.
    @Test("a screen drawn with the accessibility switch off fails rather than passes")
    func switchedOffFails() async {
        #expect(ScreenImage.listen(), "the switch exists on this runtime")
        ScreenImage.listen(false)
        defer { ScreenImage.listen(true) }

        await withKnownIssue("the harness hears nothing and says so") {
            let rendered = await ScreenImage.write("harness-switched-off", size: CGSize(width: 300, height: 200)) {
                Text("Something to say")
            }
            #expect(!rendered.says("Something to say"))
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("said nothing") }
        }
    }

    @Test("a screen that says nothing fails rather than passes")
    func silenceFails() async {
        await withKnownIssue("an empty screen is a failure, not a pass") {
            _ = await ScreenImage.write("harness-silent", size: CGSize(width: 300, height: 200)) {
                Color.clear
            }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("said nothing") }
        }
    }

    @Test("a screen that never settles fails, saying what it last said")
    func neverSettlingFails() async {
        await withKnownIssue("the wait is bounded") {
            _ = await ScreenImage.write("harness-unsettled", size: CGSize(width: 300, height: 200), interact: { _ in
                await ScreenImage.settle(until: { $0.contains("never") })
            }) {
                Text("always")
            }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("did not settle") && $0.rawValue.contains("always") }
        }
    }

    /// A button of a known size in a known place comes back there, in the window's own points.
    @Test("each word comes back with its frame in window points")
    func framesAreInWindowPoints() async throws {
        let size = CGSize(width: 300, height: 400)
        let rendered = await ScreenImage.write("harness-frames", size: size) {
            VStack(spacing: 0) {
                Spacer().frame(height: 100)
                Button {} label: { Text("Press").frame(width: 120, height: 50) }
                Spacer()
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        let frame = try #require(rendered.frames(of: "Press").first)
        #expect(abs(frame.midX - 150) < 1 && abs(frame.minY - 100) < 1, "\(frame)")
        #expect(frame.width >= 44 && frame.height >= 44, "a control is at least 44×44 pt")
        #expect(rendered.bounds == CGRect(origin: .zero, size: size))
        #expect(rendered.safeArea.contains(frame))
    }
}

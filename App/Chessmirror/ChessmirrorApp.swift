import ChessmirrorKit
import SwiftUI

@main
struct ChessmirrorApp: App {
    @State private var engine = EngineHost(nets: {
        // The app's answer to "where are the weights" (docs/adr/0002): they ride in the bundle.
        guard let big = Bundle.main.url(forResource: "nn-c288c895ea92", withExtension: "nnue", subdirectory: "Nets"),
              let small = Bundle.main.url(forResource: "nn-37f18f62d772", withExtension: "nnue", subdirectory: "Nets")
        else { return nil }
        return EngineHost.Nets(big: big, small: small)
    })
    @State private var library = GameLibrary()
    /// The 错题本, kept beside the library rather than inside it: it is derived from the games
    /// and from the practice log, and it is a cache that can be thrown away at any moment
    /// (docs/adr/0028, docs/adr/0029).
    @State private var book = MistakeIndex()
    /// What language every word on every screen comes out in. Read before the first screen is
    /// built, so a person who chose one gets it on the launch screen rather than one frame later.
    @State private var language = LanguageSetting.shared
    /// The 搜索预算, read here so that the kit has the player's budget before any search runs.
    @State private var search = SearchSetting.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryScreen()
                .environment(engine)
                .environment(library)
                .environment(book)
                .environment(language)
                // The one thing in the app that rebuilds every screen: the words on all of them
                // change at once, and there is no other way to tell SwiftUI that a plain function
                // call started answering differently. Changing language is a deliberate, rare act
                // — the price is the navigation stack, which is a fair one for it.
                .id(language.current)
                // The kit's `Sounds` is a seam holding whichever Feedback was installed on the
                // way up; the app installs its own, and everything that plays goes through it.
                .task { _ = SystemFeedback.shared }
                .task { await engine.start() }
                // Finding the iCloud folder and moving the old games into it, once, after the
                // local folder has already been listed and drawn (docs/adr/0012).
                .task { await library.connect() }
                // The only reader of the scene phase in the app: it is turned into
                // `engine.isActive` here, and everything that cares watches that instead.
                // `initial` matters for a launch that never reaches `.active` — into the
                // background for a fetch, say — where there is no change to hear about.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    engine.setActive(phase == .active)
                }
        }
    }
}

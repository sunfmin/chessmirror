import ChessfenKit
import SwiftUI

/// What this app is made of, and where to get it.
///
/// Stockfish is GPLv3 and this links against it, so the whole thing is GPLv3 (docs/adr/0001)
/// — which obliges anyone handing the binary to somebody else to hand over the licence and a
/// way to the source too. That is easiest to honour if the app carries both itself.
struct AboutScreen: View {
    @Environment(EngineHost.self) private var engine
    @Environment(GameLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Bindable private var language = LanguageSetting.shared

    private static let source = URL(string: "https://github.com/sunfmin/chessfen")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(localized("app.name")).font(.title2.bold())
                            Text(localized("app.mark")).eyebrow()
                        }
                        Text(localized("about.what"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                // The language, high up and named in itself, so somebody handed a phone speaking
                // a language they do not read can find the way out of it. Following the phone is
                // the top row and the one everybody starts on; the other eight say what they are
                // in their own words, because a list of languages written in one language is a
                // list only the people who already read that language can use.
                Section {
                    Picker(selection: $language.chosen) {
                        Text(localized("about.language.system")).tag(Language?.none)
                        ForEach(Language.allCases) { candidate in
                            Text(candidate.endonym).tag(Language?.some(candidate))
                        }
                    } label: {
                        Text(localized("about.language"))
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text(localized("about.language"))
                } footer: {
                    Text(localized("about.language.explained"))
                }

                Section(localized("about.version")) {
                    row(localized("app.name"), Self.version)
                    row(localized("about.engine"), "Stockfish 18")
                    switch engine.status {
                    case .ready: row(localized("about.engineStatus"), localized("about.ready"))
                    case .starting:
                        row(localized("about.engineStatus"), localized("about.starting"))
                    case .unavailable:
                        row(localized("about.engineStatus"), engine.unavailableReason ?? "")
                    }
                }

                // Where the games are is worth saying out loud: it is the difference between a
                // game that is on every device and one that is on this one, and the only way to
                // tell from inside the app that iCloud is switched on.
                Section {
                    row(
                        localized("about.storedIn"),
                        localized(library.folder.isCloud ? "about.iCloud" : "about.thisDevice")
                    )
                } header: {
                    Text(localized("about.storage"))
                } footer: {
                    Text(
                        localized(
                            library.folder.isCloud
                                ? "about.storage.cloud" : "about.storage.local"
                        )
                    )
                }

                Section {
                    Link(destination: Self.source) {
                        Label(
                            localized("about.source"),
                            systemImage: "chevron.left.forwardslash.chevron.right"
                        )
                    }
                } header: {
                    Text(localized("about.licence"))
                } footer: {
                    Text(localized("about.licence.explained"))
                }
            }
            .navigationTitle(localized("about"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(localized("done")) { dismiss() }
                }
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }
}

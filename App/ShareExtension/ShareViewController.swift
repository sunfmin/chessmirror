import ChessmirrorKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 棋镜 in somebody else's share sheet.
///
/// The extension does one thing: it takes the picture and puts it where the app will find it
/// (`SharedInbox`). It does not recognise anything. Recognition needs the piece Templates and
/// a second of work, and an extension is a guest in another app's process with a memory limit
/// measured in tens of megabytes and a lifetime measured in the seconds before the sheet is
/// dismissed — so it hands over the bytes and gets out of the way, and the board is read by
/// the app, on the app's own Confirm Position screen (docs/adr/0008).
///
/// What it shows while doing that is a sentence and a button. The share sheet is a modal over
/// somebody else's app and dismissing it silently would leave no sign anything happened; this
/// says what landed and offers to go and look at it.
final class ShareViewController: UIViewController {
    private let arrival = Arrival()

    override func viewDidLoad() {
        super.viewDidLoad()
        let panel = UIHostingController(
            rootView: SharePanel(
                arrival: arrival,
                open: { [weak self] in self?.openTheApp() },
                close: { [weak self] in self?.finish() }
            )
        )
        addChild(panel)
        panel.view.frame = view.bounds
        panel.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(panel.view)
        panel.didMove(toParent: self)
        Task { arrival.state = await receive() }
    }

    // ------------------------------------------------------------------ taking it in

    private func receive() async -> Arrival.State {
        guard let data = await sharedPicture() else { return .failed }
        guard let inbox = SharedInbox.shared, (try? inbox.deposit(data)) != nil else {
            return .failed
        }
        return .kept
    }

    /// The first image among the attachments, as bytes.
    ///
    /// Bytes rather than a `UIImage`: the picture goes to disk and then to `BoardIntake`,
    /// which decodes straight to the size the recogniser reads at. Turning it into a
    /// `UIImage` here would be decoding a screenshot twice in the process least able to
    /// afford it.
    private func sharedPicture() async -> Data? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                else { continue }
                if let data = await provider.loadImageData() { return data }
            }
        }
        return nil
    }

    // ------------------------------------------------------------------ the two buttons

    private func openTheApp() {
        // An extension has no `UIApplication`, so this is the only door: the app's own URL
        // scheme, opened through the host's context. Where the system declines to bring the
        // app forward, the picture is still in the inbox and the app finds it on its own next
        // launch — so this is a shortcut, never the handoff itself.
        if let url = URL(string: "chessmirror://shared") {
            extensionContext?.open(url)
        }
        finish()
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// How far the one job has got. Observable because the view is SwiftUI and the work is not.
@Observable final class Arrival {
    enum State {
        case reading
        case kept
        case failed
    }

    var state: State = .reading
}

/// The sheet's one screen.
private struct SharePanel: View {
    let arrival: Arrival
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            switch arrival.state {
            case .reading:
                ProgressView()
                Text(localized("share.reading")).eyebrow()
            case .kept:
                Text(localized("share.kept.title"))
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Text(localized("share.kept.message"))
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
                    .multilineTextAlignment(.center)
                Button(action: open) {
                    Text(localized("share.open"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.parchment)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            case .failed:
                Text(BoardIntake.Intake.unreadableAlert.title)
                    .font(.headline)
                    .foregroundStyle(Palette.alarm)
                Text(BoardIntake.Intake.unreadableAlert.message)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSoft)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Text(localized("done"))
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSoft)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.parchment)
    }
}

extension NSItemProvider {
    /// The attachment as image bytes, whatever wrapper the sharing app used.
    ///
    /// `loadDataRepresentation` answers for a provider that has the bytes; some apps hand over
    /// a file URL instead, which is the second branch. Both end as the same `Data`.
    fileprivate func loadImageData() async -> Data? {
        let identifier = UTType.image.identifier
        let direct = await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        if let direct { return direct }
        guard
            let item = try? await loadItem(forTypeIdentifier: identifier, options: nil),
            let url = item as? URL
        else { return nil }
        return try? Data(contentsOf: url)
    }
}

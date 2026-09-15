import Darwin
import SwiftUI
import UIKit

@testable import Chessfen

/// Draws a screen the way the app draws it, writes the picture, and hands back what the screen
/// says.
///
/// This is the glue and nothing else: a window on the simulator's own screen, the real view in it,
/// long enough for it to settle, one picture. Everything a screenshot needs to vary — the game,
/// the engine, which way up the board is — a test varies for itself and passes in, so the next
/// screenshot is a new `subject` and no new plumbing.
///
/// The words come back with the picture on purpose. A PNG is for a person to look at once; the
/// list of everything the screen said is what a test can hold the screen to for ever after.
@MainActor
enum ScreenImage {
    /// Where the pictures land: `ios/App/out`, beside the source rather than deep inside
    /// DerivedData, because the whole point of them is that someone opens them.
    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent()  // ScreenTests
        .deletingLastPathComponent()  // App
        .appending(path: "out", directoryHint: .isDirectory)

    /// One rendered screen: the file it was written to, and every word it drew.
    struct Rendered {
        let url: URL
        /// The accessibility tree, flattened. It is the only account SwiftUI will give of the text
        /// it drew — and it is the same account VoiceOver reads out, so a screen that says nothing
        /// here is a screen that says nothing to anybody.
        let words: [String]

        func says(_ text: String) -> Bool { words.contains { $0.contains(text) } }
        func count(of text: String) -> Int { words.count { $0.contains(text) } }
    }

    /// - Parameters:
    ///   - size: the screen to draw on, when it is not the phone the suite is running on. A window
    ///     of a stated size has no scene and so no safe areas — which is exactly an iPhone with a
    ///     Home button, and is how a screen gets photographed at a size this run does not have. A
    ///     subject that wants a different text size or colour scheme says so itself, on its own view:
    ///     wrapping it here would put an `AnyView` in the app's own render path.
    static func write(
        _ name: String,
        style: UIUserInterfaceStyle = .light,
        size: CGSize? = nil,
        of subject: () -> some View
    ) async -> Rendered {
        _ = isListening
        let window = newWindow(style: style, size: size)
        let controller = UIHostingController(rootView: subject())
        controller.overrideUserInterfaceStyle = style
        // Clear rather than the hosting controller's default white, which would otherwise show
        // through the safe areas and light up the edges of a dark screen.
        controller.view.backgroundColor = .clear
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        await settle()

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        let url = directory.appending(path: "\(name).png")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try? image.pngData()?.write(to: url, options: .atomic)

        let rendered = Rendered(url: url, words: words(in: window))
        // The window is done with, and a key window left standing would still be the key one when
        // the next screenshot puts its own on screen.
        window.isHidden = true
        return rendered
    }

    // ----------------------------------------------------------------- plumbing

    /// Puts something on the other end of the accessibility tree, once.
    ///
    /// SwiftUI does not build that tree unless somebody is listening: with no VoiceOver there are
    /// no elements, and a screenshot test that asks what the screen says gets silence. This is the
    /// switch the UI-testing runner throws before it reads a screen, and it is only reachable by
    /// hand — which is fair enough for a lever no shipping app has any business pulling.
    private static let isListening: Bool = {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
            let symbol = dlsym(library, "_AXSSetAutomationEnabled")
        else { return false }
        typealias Listen = @convention(c) (Bool) -> Void
        unsafeBitCast(symbol, to: Listen.self)(true)
        return true
    }()

    /// A window the size of the device the test is running on, on the host app's own scene so
    /// that the safe areas are a real phone's rather than nothing at all.
    private static func newWindow(style: UIUserInterfaceStyle, size: CGSize?) -> UIWindow {
        if let size {
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.overrideUserInterfaceStyle = style
            return window
        }
        let scene = UIApplication.shared.connectedScenes.lazy
            .compactMap { $0 as? UIWindowScene }
            .first
        let window =
            scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.overrideUserInterfaceStyle = style
        return window
    }

    /// Long enough for the screen to have been told everything it is going to be told.
    ///
    /// A screen asks for its Analysis in `onAppear`, and the answer arrives on the main actor a
    /// hop later and then animates into place. A picture taken before that is a picture of a
    /// screen nobody has said anything to yet, which is not the screen anyone wanted to see.
    private static func settle() async {
        for _ in 0..<14 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A picture as RGBA pixels, so a test can hold a screen to something the words cannot say.
    ///
    /// The board's edges and the advantage bar's two ends are the things worth this: a bar whose
    /// white end is on the left when Black is at the bottom of the board reads 「优势条」 to the
    /// accessibility tree exactly as well as the right way round, and says the opposite of the
    /// number printed beside it to the one person who can see it.
    struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        init?(of url: URL) {
            guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
            let width = image.width
            let height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard
                let context = CGContext(
                    data: &bytes, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.bytes = bytes
            self.width = width
            self.height = height
        }

        /// What it looks like at one pixel — top-left origin, the way a picture is looked at.
        func colour(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
            let offset = (y * width + x) * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }

        /// Three pixels to the point on a screen drawn by this suite, which some of these readings
        /// have to be stated in to mean anything.
        func pixelsPerPoint(of size: CGSize) -> CGFloat { CGFloat(width) / size.width }
    }

    /// Everything on screen that has a word attached to it.
    private static func words(in view: UIView) -> [String] {
        var found: [String] = []
        var seen: Set<ObjectIdentifier> = []
        harvest(view, into: &found, seen: &seen)
        return found
    }

    /// Walks views and accessibility elements together, because SwiftUI draws its text into a
    /// handful of layers and hangs the words off elements that are not views at all.
    private static func harvest(
        _ node: Any, into found: inout [String], seen: inout Set<ObjectIdentifier>
    ) {
        guard let object = node as? NSObject,
            seen.insert(ObjectIdentifier(object)).inserted
        else { return }

        if let label = object.accessibilityLabel, !label.isEmpty { found.append(label) }
        if let value = object.accessibilityValue, !value.isEmpty { found.append(value) }

        if let elements = object.accessibilityElements {
            for element in elements { harvest(element, into: &found, seen: &seen) }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    guard let element = object.accessibilityElement(at: index) else { continue }
                    harvest(element, into: &found, seen: &seen)
                }
            }
        }

        if let view = object as? UIView {
            for subview in view.subviews { harvest(subview, into: &found, seen: &seen) }
        }
    }
}

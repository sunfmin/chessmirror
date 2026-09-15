import Foundation
import ImageIO

/// The one way a picture becomes a game, whichever door it came in through (docs/adr/0011).
///
/// The screens used to hand-roll the same ritual — decode, recognise, route — four times,
/// each with its own failure wording, and only the camera kept the photograph before
/// reading it. Now they hand the source here and get back one outcome to switch on; the
/// wording of a failure follows from the case, not from the call site.
public enum BoardIntake {
    /// Where a picture came from. The kit can make an `RGBImage` out of `.data` and
    /// `.file` itself; `.image` is for pixels the platform produced (the camera's
    /// `UIImage`, the clipboard) — only UIKit can hold those, so they stay the screen's
    /// job.
    public enum Source: Sendable {
        case image(RGBImage)
        case data(Data)
        case file(URL)
    }

    /// What a read made of its source.
    public enum Intake: Sendable {
        /// A legal reading: open it and play.
        ///
        /// `picture` is the board, cut out of the frame and nothing else. Kept this way
        /// rather than as the whole frame because it is the form the editor can lay under
        /// the board square for square, and because it needs no rect carried alongside it
        /// to be usable — the crop is the alignment, so it survives being written to disk
        /// and read back after a relaunch.
        case played(Game, shaky: Set<Square>, orientation: Orientation, picture: RGBImage)

        /// A board was found and read, but the reading is not a legal position. That is
        /// not a failed recognition: most often a king was read as something else, and one
        /// square is all that stands between it and a playable position — which is what
        /// the editor and the ringed Shaky Squares are for.
        case needsEditing(PositionDraft, shaky: Set<Square>, orientation: Orientation, picture: RGBImage)

        /// No board in the picture at all.
        case noBoard

        /// The source could not be made into a picture.
        case unreadable

        /// The one alert the unreadable case shows, also used by the platform failures
        /// that never made a picture and so never made an `Intake` (the camera, the
        /// clipboard).
        public static var unreadableAlert: (title: String, message: String) {
            (localized("intake.unreadable.title"), localized("intake.unreadable.message"))
        }

        /// The alert a screen shows when this outcome has to become a message, nil for
        /// the outcomes that open somewhere instead. One wording per case, owned here
        /// rather than at each call site: five sites used to write the same three
        /// failures three ways, and every one of them under a title that was true of
        /// only one.
        public var alert: (title: String, message: String)? {
            switch self {
            case .noBoard:
                (localized("intake.noBoard.title"), localized("intake.noBoard.message"))
            case .unreadable:
                Self.unreadableAlert
            case .played, .needsEditing:
                nil
            }
        }
    }

    /// Turns a source into a picture and reads it.
    ///
    /// The photograph is kept before it is read rather than after: a picture the app
    /// dies reading must still exist, or the crash takes the evidence with it. Only the
    /// camera passes a keep — the other ways in have their original elsewhere already,
    /// and a kept copy of an album picture would only litter the folder.
    public static func read(
        _ source: Source,
        keepingPhotograph: (@MainActor (RGBImage) -> Void)? = nil
    ) async -> Intake {
        guard let image = decode(source) else { return .unreadable }
        if let keepingPhotograph {
            await MainActor.run { keepingPhotograph(image) }
        }
        let recognition = await Task.detached(priority: .userInitiated) {
            try? await Recognizer.recognise(photograph: image)
        }.value

        // No board in the picture at all — the only thing the noBoard message is true about.
        guard let recognition, let draft = PositionDraft(fen: recognition.fen) else {
            return .noBoard
        }
        let shaky = Set(recognition.shaky.map(\.square))
        let picture = recognition.boardPicture

        // A legal reading opens as a game, which is the whole point of 0011. An illegal
        // one opens the editor rather than being thrown away behind a message blaming the
        // photograph, which is what it used to do.
        guard let game = Game(startFEN: recognition.fen) else {
            return .needsEditing(
                draft, shaky: shaky, orientation: recognition.orientation, picture: picture
            )
        }
        return .played(game, shaky: shaky, orientation: recognition.orientation, picture: picture)
    }

    // ---------------------------------------------------------------- decoding

    /// The source as pixels, nil when it could not be made into one. Public because the
    /// CLI wants the picture for its own recognition diagnostics.
    ///
    /// A recent iPhone hands over a 48-megapixel photograph, which as an `RGBImage` is
    /// 144 MB of bytes for a board the recogniser reads at 1200 pixels; decoding straight
    /// to a thumbnail avoids ever holding the full thing.
    public static func decode(_ source: Source) -> RGBImage? {
        switch source {
        case .image(let image):
            return image
        case .data(let data):
            return thumbnail(from: CGImageSourceCreateWithData(data as CFData, nil))
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return thumbnail(from: CGImageSourceCreateWithURL(url as CFURL, nil))
        }
    }

    private static func thumbnail(from source: CGImageSource?) -> RGBImage? {
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Imaging.decodedLongestSide,
            // Photographs carry their rotation in EXIF. Without this a board shot in
            // portrait arrives on its side, and every square is in the wrong place.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return RGBImage(cgImage: cgImage)
    }
}

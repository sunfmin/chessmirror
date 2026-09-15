import ChessfenKit
import SwiftUI
import UIKit

/// Getting a picture of a board into the shape the recogniser wants, when the platform
/// produced it as a `UIImage`: the camera and the clipboard. Data and files decode inside
/// `BoardIntake`, which owns the whole way in; these two are the ways only UIKit can hold.
enum BoardImageLoader {
    /// The camera hands over a `UIImage` whose orientation lives in metadata; drawing it
    /// once settles that as well as bounding its size.
    static func image(from uiImage: UIImage) -> RGBImage? {
        let longest = max(uiImage.size.width, uiImage.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, CGFloat(Imaging.decodedLongestSide) / longest)
        let target = CGSize(
            width: (uiImage.size.width * scale).rounded(),
            height: (uiImage.size.height * scale).rounded()
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let flattened = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let cgImage = flattened.cgImage else { return nil }
        return RGBImage(cgImage: cgImage)
    }

    static func fromClipboard() -> RGBImage? {
        guard let image = UIPasteboard.general.image else { return nil }
        return self.image(from: image)
    }

    static var clipboardHasImage: Bool { UIPasteboard.general.hasImages }
}

/// An `RGBImage` as something SwiftUI can show.
extension Image {
    init?(rgb: RGBImage) {
        guard let cgImage = rgb.cgImage else { return nil }
        self.init(decorative: cgImage, scale: 1, orientation: .up)
    }
}

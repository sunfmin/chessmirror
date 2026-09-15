/// The twelve Templates the matcher scores a Silhouette against.
///
/// Derived from `PiecePaths` on first use rather than shipped as image assets, for the
/// same reason the Python original did it: the shapes then have exactly one home, and a
/// Template cannot drift from the piece the player is looking at.
public enum PieceTemplates {
    /// Side of the normalised shape space, in pixels.
    public static let shapeSize = 64
    /// Rasterisation size — larger than `shapeSize`, so downscaling stays smooth.
    private static let rasterSize = 256

    /// In the order the matcher tries them, which is only cosmetic: every one is scored.
    public static let kinds: [PieceKind] = [.pawn, .knight, .bishop, .rook, .queen, .king]

    /// Normalised Silhouettes for one side, as `(kind, mask)` pairs.
    public static func shapes(for colour: PieceColour) -> [(kind: PieceKind, mask: Mask)] {
        colour == .white ? white : black
    }

    private static let white = build(.white)
    private static let black = build(.black)

    private static func build(_ colour: PieceColour) -> [(kind: PieceKind, mask: Mask)] {
        kinds.compactMap { kind in
            guard let document = SVGDocument(glyph: Piece(colour: colour, kind: kind).glyph),
                  let raster = document.silhouette(size: rasterSize)
            else { return nil }
            return (kind, Morphology.normalise(raster, size: shapeSize))
        }
    }
}

// swift-tools-version: 6.2
import PackageDescription

// The define set the Stockfish Makefile uses for ARCH=apple-silicon. It is 64-bit ARM
// only, which is every device this app can be installed on and the machine it is built
// on; an Intel Mac would need its own set, and does not get one.
//
// The dotprod flag is worth its awkwardness: measured on this Mac it takes the start
// position from 11.0M to 12.5M nodes per second, about 14%, and it is the NNUE evaluation
// — the app's whole reason for a move — that gets faster. SwiftPM classes -march as an
// unsafe flag, so this package can never be a versioned dependency of another; it is the
// root package and a local one, which is the case where that restriction costs nothing.
// Should some future Xcode refuse it anyway, dropping these two lines gives back a
// working build at the older speed.
let stockfishDefines: [CXXSetting] = [
    .define("NDEBUG"),
    // Pinned rather than inherited, because what Xcode hands a package target is the app's
    // optimisation level and that is `-O0` in Debug. An unoptimised Stockfish is not a
    // slightly slower Stockfish: with libc++ uninlined, a one-line `basic_string::__is_long`
    // is the top entry in a profile, and the search burns cores to reach a depth an
    // optimised build reaches in a fraction of the time. Debug builds are what a day of
    // development actually runs, so they get the same `-O3` the Stockfish Makefile uses;
    // the cost is that the vendored C++ cannot be stepped through, which is not something
    // anyone does to it.
    .unsafeFlags(["-O3"]),
    .define("IS_64BIT"),
    .define("USE_PREFETCH"),
    .define("USE_POPCNT"),
    .define("USE_PTHREADS"),
    .define("USE_NEON", to: "8"),
    .define("USE_NEON_DOTPROD"),
    .unsafeFlags(["-march=armv8.2-a+dotprod"]),
    // The NNUE networks ship as bundle resources and are loaded by path, so incbin's
    // assembly embedding never has to work under Xcode.
    .define("NNUE_EMBEDDING_OFF"),
]

let package = Package(
    name: "chessfen",
    // The language the words were written in first. Every other one falls back to it, and a
    // package with localized resources has to name one (docs/adr/0019).
    defaultLocalization: "zh-Hans",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "ChessfenKit", targets: ["ChessfenKit"]),
        .executable(name: "chessfen-cli", targets: ["chessfen-cli"]),
    ],
    targets: [
        .target(
            name: "CStockfish",
            exclude: [
                "stockfish/VENDORED.txt",
                "stockfish/incbin/UNLICENCE",
            ],
            publicHeadersPath: "include",
            cxxSettings: stockfishDefines
        ),
        .target(
            name: "ChessfenKit",
            dependencies: ["CStockfish"],
            // Eight folders of words, one per language, and every word the app says comes out of
            // them — the screens' as much as the package's own (docs/adr/0019). A folder rather
            // than a String Catalog because `swift build` copies an `.xcstrings` without
            // compiling it, so a catalog would work in Xcode and say nothing from the terminal.
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "chessfen-cli", dependencies: ["ChessfenKit"]),
        .testTarget(
            name: "ChessfenKitTests",
            // CStockfish directly, for the seam tests: they feed synthetic info frames to
            // the depth grouper, and a frame is the bridge's own struct.
            dependencies: ["ChessfenKit", "CStockfish"],
            // Real pictures of real boards, the same ones the app reads: a different
            // piece set, inline coordinates, a highlighted square. Nothing rendered
            // here can stand in for them. The whole folder rather than the three files
            // it currently holds, so a fixture added to Resources/ is in the bundle
            // without a second edit here.
            resources: [.copy("Resources")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

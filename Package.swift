// swift-tools-version: 6.2
import PackageDescription

// The define set the Stockfish Makefile uses for ARCH=armv8, which is 64-bit ARM with NEON and
// nothing newer: every device this app can be installed on and the machine it is built on. An
// Intel Mac would need its own set, and does not get one.
//
// Not ARCH=apple-silicon. That set adds the dotprod instructions, which took the start position
// from 11.0M to 12.5M nodes per second on this Mac — and which an A12 does not have. iPadOS 26
// still runs on A12 iPads (the first iPad Pro 11-inch among them), and there the first NNUE
// evaluation is an illegal instruction: the app dies the moment the engine looks at a board.
// No App Store device requirement can exclude an A12, so the build stops asking for the
// instruction instead, and every device pays the 14%.
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
    // The NNUE networks ship as bundle resources and are loaded by path, so incbin's
    // assembly embedding never has to work under Xcode.
    .define("NNUE_EMBEDDING_OFF"),
]

let package = Package(
    name: "chessmirror",
    // The language the words were written in first. Every other one falls back to it, and a
    // package with localized resources has to name one (docs/adr/0019).
    defaultLocalization: "zh-Hans",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "ChessmirrorKit", targets: ["ChessmirrorKit"]),
        // The fakes at the kit's seams, for any test bundle that drives the real code above them:
        // the package's own tests and the app's screen tests both.
        .library(name: "ChessmirrorKitTesting", targets: ["ChessmirrorKitTesting"]),
        .executable(name: "chessmirror-cli", targets: ["chessmirror-cli"]),
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
            name: "ChessmirrorKit",
            dependencies: ["CStockfish"],
            // Eight folders of words, one per language, and every word the app says comes out of
            // them — the screens' as much as the package's own (docs/adr/0019). A folder rather
            // than a String Catalog because `swift build` copies an `.xcstrings` without
            // compiling it, so a catalog would work in Xcode and say nothing from the terminal.
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "chessmirror-cli", dependencies: ["ChessmirrorKit"]),
        .target(name: "ChessmirrorKitTesting", dependencies: ["ChessmirrorKit"]),
        .testTarget(
            name: "ChessmirrorKitTests",
            // CStockfish directly, for the seam tests: they feed synthetic info frames to
            // the depth grouper, and a frame is the bridge's own struct.
            dependencies: ["ChessmirrorKit", "ChessmirrorKitTesting", "CStockfish"],
            // Real pictures of real boards, the same ones the app reads: a different
            // piece set, inline coordinates, a highlighted square. Nothing rendered
            // here can stand in for them. The whole folder rather than the three files
            // it currently holds, so a fixture added to Resources/ is in the bundle
            // without a second edit here. Copied as a folder, so it is a folder *inside* the
            // bundle's resources and the tests look in `subdirectory: "Resources"`: the old
            // build system's flat bundle made that folder the resource directory itself by
            // accident, and swiftbuild's `Contents/Resources/` does not.
            resources: [.copy("Resources")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

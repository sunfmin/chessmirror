// swift-tools-version: 6.2
import PackageDescription

// The define set the Stockfish Makefile uses for ARCH=armv8: 64-bit ARM with NEON and nothing
// newer, which every device this app can be installed on has. An Intel Mac would need its own
// set, and does not get one.
//
// The engine is built twice from the one vendored tree: with this set in CStockfish, and with
// ARCH=apple-silicon's dotprod added in CStockfishDotprod. Each engine is started on the build
// its CPU can run, and why is docs/adr/0052.
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

// What ARCH=apple-silicon adds to ARCH=armv8, and the rename that lets both builds be linked
// into one binary: every Stockfish symbol is in `namespace Stockfish`, so defining the name
// moves the whole second copy aside without touching a vendored line (docs/adr/0052).
let dotprodDefines: [CXXSetting] = stockfishDefines + [
    .define("USE_NEON_DOTPROD"),
    .unsafeFlags(["-march=armv8.2-a+dotprod"]),
    .define("Stockfish", to: "StockfishDotprod"),
    .headerSearchPath("../CStockfish/include"),
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
            dependencies: ["CStockfishDotprod"],
            exclude: [
                "stockfish/VENDORED.txt",
                "stockfish/incbin/UNLICENCE",
            ],
            publicHeadersPath: "include",
            cxxSettings: stockfishDefines
        ),
        // CStockfish's stockfish/ and engine/ again, by symlink, built with dotprod. Nothing
        // but bridge.cpp calls into it.
        .target(
            name: "CStockfishDotprod",
            exclude: [
                "stockfish/VENDORED.txt",
                "stockfish/incbin/UNLICENCE",
            ],
            // No header of its own is anyone's business; engine_build.h is the one bridge.cpp reads.
            publicHeadersPath: "engine",
            cxxSettings: dotprodDefines
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

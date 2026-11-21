import CStockfish
import Darwin

/// Which of the two Stockfish builds the engine runs on (docs/adr/0052).
///
/// The same engine from the same vendored sources, built twice: `dotprod` uses the ARMv8.2
/// dot-product instructions in its NNUE layers and is the faster, and on a CPU without them —
/// an A12, which iPadOS 26 still runs on — its first evaluation is an illegal instruction.
/// `armv8` runs everywhere. The choice is made once, when the engine is created, from what the
/// CPU says, and never from what the device is called.
public enum EngineBuild: String, Hashable, Sendable {
    case armv8
    case dotprod

    /// The build `cpu` can run, and the faster of the two where it can run both.
    public init(for cpu: CPUFeatures) {
        self = cpu.hasDotProd ? .dotprod : .armv8
    }

    init(_ build: CfEngineBuild) {
        self = build == CF_BUILD_DOTPROD ? .dotprod : .armv8
    }

    var bridged: CfEngineBuild {
        switch self {
        case .armv8: CF_BUILD_ARMV8
        case .dotprod: CF_BUILD_DOTPROD
        }
    }
}

/// What the CPU says it can do, as far as choosing a build turns on it. A value rather than a
/// question asked inline, so a test can be a CPU that cannot.
public struct CPUFeatures: Hashable, Sendable {
    public var hasDotProd: Bool

    public init(hasDotProd: Bool) {
        self.hasDotProd = hasDotProd
    }

    /// This machine's, from the kernel. A key the kernel does not know reads as absent, which
    /// is the safe answer: armv8 runs on anything.
    public static let current = CPUFeatures(hasDotProd: sysctlFlag("hw.optional.arm.FEAT_DotProd"))

    private static func sysctlFlag(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && value != 0
    }
}

import Foundation
import Testing

/// Contract: a footprint check runs with nothing beside it. scripts/test.sh runs
/// `RecognitionMemoryTests` alone and the rest side by side; these hold that a test reading the
/// process's memory any other way, or from the side-by-side run, cannot pass.
@Suite struct FootprintTests {
    /// Every way a test could read what the process holds goes through `Footprint.now()`, the one
    /// read the side-by-side run refuses. A test that called task_info or getrusage itself would
    /// measure its neighbours and say nothing.
    @Test func onlyFootprintReadsTheProcessMemory() throws {
        let tests = URL(filePath: #filePath).deletingLastPathComponent()
        let reads = /task_info|TASK_VM_INFO|phys_footprint|resident_size|rusage|ru_maxrss|mach_task_basic_info|os_proc_available_memory|mstats|malloc_zone_statistics/
        let files = try FileManager.default.contentsOfDirectory(at: tests, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "the scan sees the test sources")
        var readers: [String] = []
        for file in files where file.lastPathComponent != "Footprint.swift" && file.lastPathComponent != "FootprintTests.swift" {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if code.contains(where: { $0.contains(reads) }) { readers.append(file.lastPathComponent) }
        }
        #expect(readers.isEmpty, "read the footprint with Footprint.now(), in a suite scripts/test.sh runs alone: \(readers)")
    }

    /// The side-by-side run is the one with CHESSMIRROR_TESTS_SIDE_BY_SIDE set; a footprint read
    /// there is an issue, so a footprint check that landed in it fails.
    @Test(.enabled(if: ProcessInfo.processInfo.environment[Footprint.sideBySide] != nil))
    func aFootprintReadBesideOtherTestsFails() {
        withKnownIssue {
            _ = Footprint.now()
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("scripts/test.sh runs alone") }
        }
    }
}

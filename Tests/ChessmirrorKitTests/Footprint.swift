import Darwin
import Foundation
import Testing

/// The physical footprint of this test process, in bytes: the one place a test reads it.
///
/// A footprint is a fact about the whole process, so a test that reads one says something true
/// only with no other test running in it. scripts/test.sh runs the suite as two processes: the
/// footprint checks (`RecognitionMemoryTests`) one at a time and alone, and everything else
/// side by side with `CHESSMIRROR_TESTS_SIDE_BY_SIDE` set. Read there, the footprint would count
/// whatever ran next door, so it records an issue instead: a footprint check that landed in the
/// side-by-side run fails, naming where it belongs. `FootprintTests` holds that no test reads the
/// footprint any other way.
enum Footprint {
    /// Set by scripts/test.sh in the run where tests run side by side.
    static let sideBySide = "CHESSMIRROR_TESTS_SIDE_BY_SIDE"

    static func now(sourceLocation: SourceLocation = #_sourceLocation) -> Int64 {
        if ProcessInfo.processInfo.environment[sideBySide] != nil {
            Issue.record(
                "the footprint was read beside other tests: put this test in a suite scripts/test.sh runs alone",
                sourceLocation: sourceLocation
            )
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int64(info.phys_footprint)
    }
}

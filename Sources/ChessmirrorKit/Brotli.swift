import Compression
import Foundation

/// Brotli, decoded through the system's own `Compression` framework.
///
/// Here for one reader: a 国象联盟 share link, whose game travels brotli-compressed in the URL
/// fragment (`PGNImport.chesseaseGame`). A streaming decode rather than the one-shot buffer
/// call, because the one-shot call has to be told how big the answer is and nothing about a
/// link says.
enum Brotli {
    static func decode(_ packed: Data) -> Data? {
        guard !packed.isEmpty else { return nil }
        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
            == COMPRESSION_STATUS_OK
        else { return nil }
        defer { compression_stream_destroy(streamPointer) }

        var out = Data()
        let result: Bool = packed.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = packed.count
            while true {
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = bufferSize
                let status = compression_stream_process(
                    streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                let produced = bufferSize - streamPointer.pointee.dst_size
                if produced > 0 { out.append(destination, count: produced) }
                switch status {
                case COMPRESSION_STATUS_OK:
                    // More to come only when the buffer was filled; an unfilled buffer with
                    // nothing left to read is a stream that will never end.
                    if produced == 0 && streamPointer.pointee.src_size == 0 { return false }
                    continue
                case COMPRESSION_STATUS_END:
                    return true
                default:
                    return false
                }
            }
        }
        return result ? out : nil
    }
}

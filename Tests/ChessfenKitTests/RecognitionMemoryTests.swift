import ChessfenKit
import Darwin
import Foundation
import Testing

/// The physical footprint of this process, in bytes.
private func footprint() -> Int64 {
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

/// A photograph of a real board, the kind the camera hands over — a pinned fixture in
/// Resources/ rather than a path into one machine's iCloud folder, so the test runs
/// wherever the package does. `chessfen-2026-08-12-220004.png` from the app's own
/// folder, kept under a name that says what it is.
private func photographedBoard() throws -> RGBImage {
    let url = try #require(
        Bundle.module.url(forResource: "board_photograph", withExtension: "png")
    )
    return try #require(RGBImage(contentsOf: url))
}

@Test("recognising the same photograph over and over does not grow the footprint")
func recognitionFootprintIsBounded() async throws {
    let photo = try photographedBoard()
    print("[MEM] photo \(photo.width)x\(photo.height)")

    // Warm up once: the first run builds whatever is built once.
    _ = try? await Recognizer.recognise(photograph: photo)
    let before = footprint()
    var peak = before
    var after: [Int64] = []
    print("[MEM] baseline \(before / 1_048_576) MB")

    for iteration in 1...12 {
        _ = try? await Recognizer.recognise(photograph: photo)
        let now = footprint()
        peak = max(peak, now)
        after.append(now)
        print("[MEM] after \(iteration): \(now / 1_048_576) MB")
    }

    print("[MEM] peak growth \((peak - before) / 1_048_576) MB")
    // A healthy run allocates and releases: whatever pools and caches exist fill in the
    // first couple of runs and then stop, so the settled tail is the leak detector — a
    // plateau that stays where it is is healthy, and one that climbs is the phone dying.
    //
    // The suites run side by side, so any one sample is knocked about by whatever the
    // engine tests are doing next door; a single high or low reading proves nothing.
    // A trend cannot hide in noise the way a sample can, so the tail's later half is
    // weighed against its earlier half: a plateau stays level, and a leak climbs.
    let tail = Array(after[4...])
    let split = tail.count / 2
    let earlier = tail.prefix(split).reduce(0, +) / Int64(split)
    let later = tail.suffix(split).reduce(0, +) / Int64(split)
    #expect(
        later - earlier < 32 * 1_048_576,
        "the tail climbed by \((later - earlier) / 1_048_576) MB between its halves"
    )
    // The peak is *printed* and not asserted on, for the reason given just above: it is one
    // sample of the whole process, so the engine suite loading a 108 MB net next door lands
    // in it and reads as a recognition that grew. It failed exactly that way once twelve
    // unrelated tests joined the process. What it was reaching for — that no single
    // recognition spikes — is measured properly by the three tests below, each of which
    // samples *during* one scoped run against a baseline taken immediately before it.
    _ = peak
}

/// The highest footprint seen while `body` runs, sampled every fifty milliseconds.
///
/// The loop above samples *between* recognitions, which cannot see a spike that builds and
/// releases inside one run. The phone died mid-recognition, so the peak during one run is
/// the number that matters.
private func peakFootprint(while body: () async -> Void) async -> Int64 {
    let sampler = Task {
        var peak: Int64 = 0
        while !Task.isCancelled {
            peak = max(peak, footprint())
            try? await Task.sleep(for: .milliseconds(50))
        }
        return peak
    }
    await body()
    sampler.cancel()
    return await sampler.value
}

/// A board photograph pasted onto a white page, the way a score sheet carries one: a busy
/// page around it, so Vision's rectangle hunt has something to hunt.
private func scoreSheetStyle(_ photo: RGBImage) throws -> RGBImage {
    let pageWidth = 1600, pageHeight = 2200
    let board = photo.resized(width: 800, height: 800)
    var pixels = [UInt8](repeating: 248, count: pageWidth * pageHeight * 3)
    let left = (pageWidth - board.width) / 2
    let top = (pageHeight - board.height) / 2
    for y in 0..<board.height {
        for x in 0..<board.width {
            let from = (y * board.width + x) * 3
            let to = ((top + y) * pageWidth + (left + x)) * 3
            pixels[to] = board.pixels[from]
            pixels[to + 1] = board.pixels[from + 1]
            pixels[to + 2] = board.pixels[from + 2]
        }
    }
    // A few grey bars as text lines, so the page reads as a document.
    for line in 0..<6 {
        let y = 200 + line * 120
        for x in 200..<1400 {
            let base = (y * pageWidth + x) * 3
            pixels[base] = 90
            pixels[base + 1] = 90
            pixels[base + 2] = 90
        }
    }
    return RGBImage(width: pageWidth, height: pageHeight, pixels: pixels)
}

/// The minimised repro: nothing but the refinement descent on a page-sized quad. The full
/// recognition brings Vision and the direct read along for the ride, but this is the loop
/// that piles the memory — it must reproduce the spike on its own, in seconds rather than
/// minutes, for the fix to be testable at speed.
@Test("refining a page-sized quad does not spike the footprint")
func refinementPeakIsBounded() async throws {
    let page = try scoreSheetStyle(photographedBoard())
    let quad = BoardQuad(rect: CGRect(x: 0, y: 0, width: page.width, height: page.height))
    let baseline = footprint()
    let peak = await peakFootprint {
        _ = PerspectiveCorrection.refined(quad, in: page)
    }
    print("[MEM] refine: baseline \(baseline / 1_048_576) MB, peak \(peak / 1_048_576) MB")
    #expect(
        peak - baseline < 1024 * 1_048_576,
        "footprint spiked by \((peak - baseline) / 1_048_576) MB during one refinement"
    )
}

@Test("the peak footprint during one recognition stays under a gigabyte")
func recognitionPeakIsBounded() async throws {
    let photo = try photographedBoard()
    _ = try? await Recognizer.recognise(photograph: photo)
    for (label, image) in [("board", photo), ("score-sheet", try scoreSheetStyle(photo))] {
        let baseline = footprint()
        let peak = await peakFootprint {
            _ = try? await Recognizer.recognise(photograph: image)
        }
        print("[MEM] \(label): baseline \(baseline / 1_048_576) MB, peak \(peak / 1_048_576) MB")
        // The phone's kill came mid-recognition. A transient multi-gigabyte spike here is
        // the same thing at a smaller scale.
        #expect(
            peak - baseline < 1024 * 1_048_576,
            "\(label): footprint spiked by \((peak - baseline) / 1_048_576) MB during one recognition"
        )
    }
}

/// The exact photograph the phone was holding when the system killed it, pinned in
/// Resources/ — `chessfen-photo-2026-08-13-080920.png` from the app's own folder. The
/// strongest check there is: the input that died before the fix must be read, bounded,
/// by the pipeline after it.
@Test("the photograph that killed the phone is read within a bounded footprint")
func thePhonePhotoThatKilledTheAppIsBounded() async throws {
    let url = try #require(
        Bundle.module.url(forResource: "killer_photograph", withExtension: "png")
    )
    let photo = try #require(RGBImage(contentsOf: url))
    let baseline = footprint()
    let peak = await peakFootprint {
        _ = try? await Recognizer.recognise(photograph: photo)
    }
    print(
        "[MEM] phone photo \(photo.width)x\(photo.height): "
            + "baseline \(baseline / 1_048_576) MB, peak \(peak / 1_048_576) MB"
    )
    #expect(
        peak - baseline < 1024 * 1_048_576,
        "footprint spiked by \((peak - baseline) / 1_048_576) MB on the phone's own photograph"
    )
}

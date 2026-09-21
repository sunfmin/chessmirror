import AVFoundation
import ChessmirrorKit
import Foundation
import UIKit

/// The app's adapter for `Feedback`: what a move sounds and feels like on a phone.
///
/// The sounds are synthesised here rather than shipped as files. Partly because the app has
/// no business downloading anything — that is the whole premise — and partly because what a
/// piece landing on a board sounds like is a short noise burst with a low body under it, and
/// that is four lines of arithmetic. It also means the sounds scale, mix and never go out of
/// sync with a bundle.
///
/// Everything here fails quietly. An app that cannot make a noise is an app that cannot make
/// a noise; it is not an app that should refuse to play chess.
@MainActor final class SystemFeedback: Feedback {
    static let shared = SystemFeedback()

    private let engine = AVAudioEngine()
    /// Four players so that sounds in quick succession overlap instead of cutting each other
    /// off — which is what happens when the engine replies the instant you move.
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [FeedbackSound: AVAudioPCMBuffer] = [:]
    private var isRunning = false
    /// When each sound was last played, so that a finger drumming on the board does not stack
    /// ten copies of the same buffer into a single loud smear.
    private var lastPlayed: [FeedbackSound: ContinuousClock.Instant] = [:]
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .medium)

    private init() {
        // This is the seam working: the kit's `Sounds` is handed the app's adapter on the way
        // up, and everything that plays a sound goes through it from then on. A test that wants
        // silence or a recording replaces `Sounds.current` before it builds its screens.
        Sounds.current = self
    }

    // ------------------------------------------------------------------ using

    func play(_ sound: FeedbackSound) {
        touch(sound)
        // Off is the player's setting, and it travels (docs/adr/0012).
        guard PlayerSettings.shared.isSoundOn else { return }
        // Two taps closer together than this are one gesture as far as the ear is concerned, and
        // playing both only makes a louder version of one.
        let now = ContinuousClock.now
        if let last = lastPlayed[sound], now - last < .milliseconds(45) { return }
        lastPlayed[sound] = now

        start()
        guard isRunning, let buffer = buffers[sound], !players.isEmpty else { return }
        // Scheduled onto a player that is already running, never stopped and restarted: stopping
        // a node mid-buffer cuts the waveform wherever it happens to be, and a waveform cut at a
        // non-zero sample is exactly what a click is.
        let player = players[next % players.count]
        next += 1
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    /// The haptics, which are the half of this that works with the ringer off.
    private func touch(_ sound: FeedbackSound) {
        switch sound {
        case .move: impact.impactOccurred(intensity: 0.7)
        case .capture, .gameOver: heavyImpact.impactOccurred()
        case .check: heavyImpact.impactOccurred(intensity: 0.8)
        case .refused: impact.impactOccurred(intensity: 0.4)
        }
    }

    /// Started on first use rather than at launch: nothing should be holding an audio
    /// session open for a game that has not begun.
    private func start() {
        guard !isRunning else { return }
        // Ambient, mixing with others: a chess app has no business stopping anybody's music,
        // and it should go quiet when the ringer switch says so.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)
        guard let format else { return }

        for sound in FeedbackSound.allCases {
            buffers[sound] = Self.render(sound, format: format)
        }
        for _ in 0..<4 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
        // Headroom. Four players can be sounding at once and the mixer sums them, so the ceiling
        // has to sit low enough that a full house still lands under 1.0 — over it, the hardware
        // clips, which is the crackle.
        engine.mainMixerNode.outputVolume = 0.85
        engine.prepare()
        do {
            try engine.start()
            // Left running with nothing scheduled, which is silence. A player that is already
            // playing can be handed a buffer without being stopped first.
            for player in players { player.play() }
            isRunning = true
        } catch {
            players = []
            buffers = [:]
        }
    }

    // --------------------------------------------------------------- synthesis

    private static let sampleRate = 44100.0

    private static func render(_ sound: FeedbackSound, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let seconds: Double =
            switch sound {
            case .move: 0.10
            case .capture: 0.18
            case .check: 0.24
            case .gameOver: 0.60
            case .refused: 0.17
            }
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frames

        // A fixed generator rather than a random one: the same tap should always make the
        // same noise, and a sound that varies run to run is a sound that cannot be judged.
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func noise() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) - 1
        }

        for frame in 0..<Int(frames) {
            let t = Double(frame) / sampleRate
            var value: Double
            switch sound {
            case .move:
                // The click of contact, then the wood under it.
                value = noise() * exp(-t * 260) * 0.55 + sin(2 * .pi * 190 * t) * exp(-t * 55) * 0.45
            case .capture:
                let crack = noise() * exp(-t * 110) * 0.6
                let body = sin(2 * .pi * 120 * t) * exp(-t * 26) * 0.5
                // The taken piece leaving, then the taking piece landing.
                let landing = t > 0.05 ? noise() * exp(-(t - 0.05) * 220) * 0.45 : 0
                value = crack + body + landing
            case .check:
                let first = t < 0.1 ? sin(2 * .pi * 880 * t) * exp(-t * 20) : 0
                let second = t >= 0.1 ? sin(2 * .pi * 1320 * (t - 0.1)) * exp(-(t - 0.1) * 16) : 0
                value = (first + second) * 0.32
            case .gameOver:
                // Three notes, falling: a game ending is not a fanfare.
                let step = 0.18
                let index = min(2, Int(t / step))
                let pitch = [660.0, 550.0, 440.0][index]
                let local = t - Double(index) * step
                value = sin(2 * .pi * pitch * local) * exp(-local * 9) * 0.28
            case .refused:
                // Two notes, the second lower, each with a harmonic under it: a "no" rather than a
                // thud. It used to be one 110 Hz sine, which is under the bottom of what a phone
                // speaker can say — the sound was there and nobody could hear it. This one arrives
                // where the ear lives, and the second note falling is what makes it a refusal
                // rather than another piece landing.
                let note = 0.07
                let index = min(1, Int(t / note))
                let pitch = [220.0, 164.0][index]
                let local = t - Double(index) * note
                let body = sin(2 * .pi * pitch * local) + 0.3 * sin(2 * .pi * pitch * 2 * local)
                value = body * exp(-local * 26) * 0.34
            }
            // Every sound is written at full scale above, because that is how the shape of it is
            // easiest to reason about; the headroom is taken once, here. Four of these can sum in
            // the mixer, and the sum has to stay inside 1.0 or the output clips.
            value *= 0.42
            // A ramp at both ends. The tail keeps the end of a buffer from clicking; the attack
            // keeps the start from doing the same, which it otherwise does, because a noise burst
            // beginning at its own peak is a step discontinuity and a step is a click.
            if t < 0.0015 { value *= t / 0.0015 }
            let tail = seconds - t
            if tail < 0.004 { value *= tail / 0.004 }
            samples[frame] = Float(max(-1, min(1, value)))
        }
        return buffer
    }
}

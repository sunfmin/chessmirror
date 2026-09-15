import AVFoundation
import ChessfenKit
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

    /// Off is a setting people genuinely want, and it belongs somewhere that survives a launch
    /// — and, since the games follow a person to their other devices (docs/adr/0012), somewhere
    /// that follows them too. A setting that has to be turned off on every device is a setting
    /// that is only half kept.
    var isSoundOn: Bool {
        didSet { Self.remember(isSoundOn) }
    }

    private static let soundKey = "chessfen.sound"

    /// Both stores, always. iCloud's is the one that travels; `UserDefaults` is the one that
    /// answers on a device with no account, and the one that answers instantly at launch
    /// before iCloud's has been read back off the network.
    private static func remember(_ isOn: Bool) {
        UserDefaults.standard.set(isOn, forKey: soundKey)
        NSUbiquitousKeyValueStore.default.set(isOn, forKey: soundKey)
    }

    /// What the setting was last left at anywhere, or nil for a person who has never touched
    /// it. iCloud wins when both have an answer: it is the more recently-informed of the two,
    /// and disagreement means another device has since had a say.
    private static func remembered() -> Bool? {
        if let travelled = NSUbiquitousKeyValueStore.default.object(forKey: soundKey) as? Bool {
            return travelled
        }
        guard UserDefaults.standard.object(forKey: soundKey) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: soundKey)
    }

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
        isSoundOn = Self.remembered() ?? true
        // This is the seam working: the kit's `Sounds` is handed the app's adapter on the way
        // up, and everything that plays a sound goes through it from then on. A test that wants
        // silence or a recording replaces `Sounds.current` before it builds its screens.
        Sounds.current = self
        // iCloud's copy arrives whenever it arrives, including while the app is open and its
        // menu on screen. Set through the property rather than around it, so that the local
        // copy is brought into line with the travelled one at the same time.
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard let travelled = Self.remembered(), travelled != SystemFeedback.shared.isSoundOn else { return }
                SystemFeedback.shared.isSoundOn = travelled
            }
        }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    // ------------------------------------------------------------------ using

    func play(_ sound: FeedbackSound) {
        touch(sound)
        guard isSoundOn else { return }
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
            case .refused: 0.13
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
                value = sin(2 * .pi * 110 * t) * exp(-t * 24) * 0.35
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

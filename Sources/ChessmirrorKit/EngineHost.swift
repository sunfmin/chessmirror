import Foundation

/// The app's one engine, and how it came to be there or not.
///
/// There is exactly one for the whole app (docs/adr/0009), so this is the thing screens
/// share rather than something they each build. Starting it means reading 112 MiB of
/// weights and building a thread pool, which is why the library is on screen first and the
/// engine arrives a moment later.
@Observable @MainActor public final class EngineHost {
    public enum Status: Equatable {
        case starting
        case ready
        /// Something is wrong with the weights, which is the only way this fails. The app
        /// still recognises boards and still lets two hands play; it just cannot advise.
        case unavailable(String)
    }

    public private(set) var status: Status = .starting
    public private(set) var service: (any Engine)?

    /// Whether the app is in front of the user. The engine searches only while it is, and this
    /// is the one place that decides so — screens observe it rather than reading the scene
    /// phase for themselves, because two definitions of "in front of the user" would sooner or
    /// later disagree about whether to be thinking.
    public private(set) var isActive = true

    public var isReady: Bool { service != nil }

    /// Why there is no engine to advise, or nil while one is on its way or ready.
    ///
    /// The one predicate the screens read for the no-engine case: they used to each choose
    /// their own — `status`, `isReady`, `service` — and three ways of asking "is the engine
    /// there" are three chances to disagree about the answer.
    public var unavailableReason: String? {
        guard case .unavailable(let reason) = status else { return nil }
        return reason
    }

    /// Where the two NNUE files are. Injected rather than read off `Bundle.main`, because the
    /// bundle is the *app's* answer and this now lives beside the engine it starts: the package's
    /// own tests and `chessmirror-cli` find the same weights in the source tree.
    private let nets: @Sendable () -> Nets?

    /// The two NNUE files sf_18 wants (docs/adr/0002).
    public struct Nets: Sendable {
        public let big: URL
        public let small: URL

        public init(big: URL, small: URL) {
            self.big = big
            self.small = small
        }
    }

    /// The standing subscriptions to this host's two facts. One list, so anything that follows
    /// the host says so here instead of keeping its own `withObservationTracking` chain.
    @ObservationIgnored private var watchers: [UUID: @MainActor () -> Void] = [:]

    public init(nets: @escaping @Sendable () -> Nets?) {
        self.nets = nets
    }

    /// A subscription to the host, which stops when this is dropped or `stop()` is called.
    public struct Watch: Sendable {
        private let stopBody: @MainActor () -> Void
        init(_ stop: @escaping @MainActor () -> Void) { stopBody = stop }
        @MainActor public func stop() { stopBody() }
    }

    /// Calls `body` every time the engine's arrival or the app's being-in-front changes.
    ///
    /// Observation fires once and forgets, so this re-arms itself: a subscriber is a standing
    /// subscription rather than a one-shot. That was the whole of what `GameSession` did for
    /// itself with a `watch` counter and its own `withObservationTracking`; one place knows how
    /// to follow the host now, and a screen or a session that follows it just says so here.
    @discardableResult
    public func onStatusChange(_ body: @escaping @MainActor () -> Void) -> Watch {
        let id = UUID()
        watchers[id] = body
        arm()
        return Watch { [weak self] in self?.watchers[id] = nil }
    }

    private func arm() {
        withObservationTracking {
            _ = isReady
            _ = isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for body in watchers.values { body() }
                // Nothing left to tell: the chain stops here rather than waking for nobody.
                if !watchers.isEmpty { arm() }
            }
        }
    }

    /// A host that is handed its engine rather than reading 112 MiB of weights to build one: how a
    /// screenshot test puts the screens into the state the app reaches a moment after it opens.
    public init(_ engine: any Engine) {
        nets = { nil }
        service = engine
        status = .ready
    }

    public func start() async {
        guard service == nil, status == .starting else { return }
        let nets = nets
        let outcome = await Task.detached(priority: .userInitiated) { Self.build(nets()) }.value
        switch outcome {
        case .success(let service):
            // The app can perfectly well have left while 112 MiB of weights were being read,
            // and an engine that arrives to an empty screen should arrive paused.
            if !isActive { service.pause() }
            self.service = service
            status = .ready
        case .failure(let failure):
            status = .unavailable(Self.explain(failure))
        }
    }

    /// The app came to the front, or left it.
    ///
    /// An unbounded Analysis left running while nobody is looking is a phone getting warm in a
    /// pocket over a position nobody is reading. Pausing stops the running search and holds a
    /// Review where it stands; resuming lets the Review carry on at the same Depth, and lets
    /// the screens start the Analysis they want again.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            service?.resume()
        } else {
            service?.pause()
        }
    }

    // The build happens off the main thread, so everything it touches is nonisolated.

    private nonisolated static func build(_ nets: Nets?)
        -> Result<EngineService, EngineService.StartupFailure>
    {
        guard let nets else { return .failure(.networkMissing) }
        let big = nets.big
        let small = nets.small
        do {
            // Two cores are left to the UI by default. The hash is smaller than the
            // desktop default because iOS will kill an app that treats a phone like a
            // workstation, and 128 MiB is plenty for the depths a game reaches.
            return .success(
                try EngineService(
                    bigNetURL: big,
                    smallNetURL: small,
                    configuration: .init(hashMegabytes: 128, multiPV: 3)
                )
            )
        } catch let failure as EngineService.StartupFailure {
            return .failure(failure)
        } catch {
            return .failure(.unknown)
        }
    }

    private nonisolated static func explain(
        _ failure: EngineService.StartupFailure
    ) -> String {
        switch failure {
        case .networkMissing: localized("engine.networkMissing")
        case .networkTooSmall: localized("engine.networkTooSmall")
        case .allocationFailed: localized("engine.allocationFailed")
        case .unknown: localized("engine.unknown")
        }
    }
}

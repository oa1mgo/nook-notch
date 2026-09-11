import Combine
import Foundation

nonisolated private final class MusicAudioAnalysisWorker: @unchecked Sendable {
    struct Update: Sendable {
        let bands: [Float]
        let appearance: MusicGlowAppearance
    }

    enum StartResult: @unchecked Sendable {
        case success
        case failure(Error)
    }

    private let capture = NookSystemAudioCapture()
    private let queue = DispatchQueue(label: "com.oaimgo.nook.music-audio-analysis", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var engine: MusicReactiveEngine?
    private var readBuffer = [Float](repeating: 0, count: 4_096)
    private var lastSampleTime: TimeInterval = 0
    private var lastPublishTime: TimeInterval = 0
    private var lastPublishedEnvelope = MusicGlowEnvelope()

    func start(
        bundleIdentifier: String?,
        onStarted: @escaping @Sendable (StartResult) -> Void,
        onUpdate: @escaping @Sendable (Update) -> Void
    ) {
        queue.async { [self] in
            stopOnQueue()
            if let error = capture.start(bundleIdentifier: bundleIdentifier) {
                onStarted(.failure(error))
                return
            }
            guard let engine = MusicReactiveEngine(sampleRate: capture.sampleRate) else {
                capture.stop()
                onStarted(.failure(NSError(domain: "com.oaimgo.nook.audio-analysis", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to initialize music frequency analysis."])))
                return
            }
            self.engine = engine
            installTimer(engine: engine, onUpdate: onUpdate)
            onStarted(.success)
        }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    func resetAnalysis() {
        queue.async { [self] in engine?.resetAnalysis() }
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        capture.stop()
        engine = nil
        lastPublishTime = 0
        lastSampleTime = 0
        lastPublishedEnvelope = MusicGlowEnvelope()
    }

    private func installTimer(
        engine: MusicReactiveEngine,
        onUpdate: @escaping @Sendable (Update) -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var endTime: TimeInterval = 0
            let sampleCount = readBuffer.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Int(self.capture.readSamples(into: baseAddress,
                    capacity: UInt(buffer.count), endingAt: &endTime))
            }
            let now = Foundation.ProcessInfo.processInfo.systemUptime
            if sampleCount > 0 {
                lastSampleTime = now
                readBuffer.withUnsafeBufferPointer { buffer in
                    engine.ingest(UnsafeBufferPointer(rebasing: buffer[..<sampleCount]),
                        endingAt: endTime, now: now)
                }
            }

            // New accents bypass the 30Hz spectrum throttle. The envelope carries
            // its original host timestamp; main-actor stalls cannot delay its peak.
            let hasNewAccent = engine.envelope != lastPublishedEnvelope
            guard hasNewAccent || now - lastPublishTime >= 1.0 / 30 else { return }
            lastPublishTime = now
            lastPublishedEnvelope = engine.envelope
            let bandGain = Float(max(0, 1 - max(now - lastSampleTime - 0.1, 0) / 0.3))
            onUpdate(Update(bands: engine.bands.map { $0 * bandGain }, appearance: engine.appearance))
        }
        self.timer = timer
        timer.resume()
    }
}

/// Keeps at most one not-yet-rendered analysis frame. If the main actor is
/// briefly busy, stale beats are replaced instead of replayed in a burst.
nonisolated private final class MusicAudioUpdateRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latestUpdate: MusicAudioAnalysisWorker.Update?
    private var isDeliveryScheduled = false

    func submit(
        _ update: MusicAudioAnalysisWorker.Update,
        deliver: @escaping @MainActor @Sendable (MusicAudioAnalysisWorker.Update) -> Void
    ) {
        lock.lock()
        latestUpdate = update
        let shouldSchedule = !isDeliveryScheduled
        if shouldSchedule {
            isDeliveryScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            while let update = takeLatest() {
                deliver(update)
            }
        }
    }

    private func takeLatest() -> MusicAudioAnalysisWorker.Update? {
        lock.lock()
        defer { lock.unlock() }
        guard let latestUpdate else {
            isDeliveryScheduled = false
            return nil
        }
        self.latestUpdate = nil
        return latestUpdate
    }
}

@MainActor
final class MusicAudioAnalyzer: ObservableObject {
    private struct Visualization: Equatable {
        let appearance: MusicGlowAppearance
        let bands: [Float]

        static let empty = Visualization(
            appearance: MusicGlowAppearance(),
            bands: [0, 0, 0, 0]
        )
    }

    enum ActivationState: Equatable {
        case idle
        case requesting
        case active
        case unavailable(String)
    }

    static let shared = MusicAudioAnalyzer()

    @Published private(set) var activationState: ActivationState = .idle
    @Published private(set) var isRunning = false
    @Published private var visualization = Visualization.empty
    @Published private var fadeOut: MusicGlowFadeOut?

    private let worker = MusicAudioAnalysisWorker()
    private var currentBundleIdentifier: String?
    private var currentTrackIdentifier: String?
    private var isStartingCapture = false
    private var startingBundleIdentifier: String?
    private var startingTrackIdentifier: String?
    private var isExplicitActivationInFlight = false
    private var pendingTrackIdentifier: String?
    private var pendingTrackResetTask: Task<Void, Never>?
    private var pendingFadeOutTask: Task<Void, Never>?
    private var requestedGeneration = 0

    private init() {}

    var glowOpacity: Double {
        let now = Foundation.ProcessInfo.processInfo.systemUptime
        return fadeOut?.opacity(at: now) ?? visualization.appearance.opacity(at: now)
    }

    var isFadingOut: Bool { fadeOut != nil }

    var realSpectrumLevels: [Float]? {
        isRunning ? visualization.bands : nil
    }

    func requestActivation(
        bundleIdentifier: String?,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        activationState = .requesting
        isExplicitActivationInFlight = true
        startCapture(
            bundleIdentifier: bundleIdentifier,
            trackIdentifier: nil,
            completion: { [weak self] result in
                self?.isExplicitActivationInFlight = false
                completion(result)
            }
        )
    }

    func sync(
        enabled: Bool,
        isPlaying: Bool,
        bundleIdentifier: String?,
        title: String,
        artist: String
    ) {
        // The caller's analysis gate also includes playback, so handle pause
        // first. Stop capture immediately; only the rendered light keeps a tail.
        guard isPlaying else {
            guard !isExplicitActivationInFlight else { return }
            if isRunning || isStartingCapture {
                stop(fadeGlow: true)
            }
            return
        }
        guard enabled else {
            // AppStorage remains false until an explicit permission request
            // succeeds. Playback metadata arriving meanwhile must not cancel
            // that request and invalidate its generation.
            guard !isExplicitActivationInFlight else { return }
            if isRunning || isStartingCapture || isFadingOut {
                stop()
            }
            return
        }

        let trackIdentifier = Self.trackIdentifier(title: title, artist: artist)
        if isStartingCapture, startingBundleIdentifier == bundleIdentifier {
            startingTrackIdentifier = trackIdentifier ?? startingTrackIdentifier
            return
        }
        if isRunning, currentBundleIdentifier == bundleIdentifier {
            scheduleTrackResetIfNeeded(to: trackIdentifier)
            return
        }

        startCapture(
            bundleIdentifier: bundleIdentifier,
            trackIdentifier: trackIdentifier
        ) { result in
            if case .failure = result {
                // Permission can be revoked in System Settings between launches.
                // Disable only the Beta analysis path. The permission-free
                // outer Music Glow remains available through its fake breathing.
                AppSettings.musicAudioReactiveGlowEnabled = false
            }
        }
    }

    func stop(fadeGlow: Bool = false) {
        let opacity = glowOpacity
        clearFadeOut()
        requestedGeneration += 1
        let generation = requestedGeneration
        if fadeGlow, opacity > 0 {
            fadeOut = MusicGlowFadeOut(startTime: Foundation.ProcessInfo.processInfo.systemUptime,
                startOpacity: opacity)
            pendingFadeOutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(MusicGlowFadeOut.duration))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled,
                      generation == self.requestedGeneration else { return }
                self.fadeOut = nil
                self.pendingFadeOutTask = nil
            }
        }
        pendingTrackResetTask?.cancel()
        pendingTrackResetTask = nil
        pendingTrackIdentifier = nil
        isStartingCapture = false
        startingBundleIdentifier = nil
        startingTrackIdentifier = nil
        isExplicitActivationInFlight = false
        isRunning = false
        visualization = .empty
        currentBundleIdentifier = nil
        currentTrackIdentifier = nil
        if activationState == .active || activationState == .requesting {
            activationState = .idle
        }
        worker.stop()
    }

    private func clearFadeOut() {
        pendingFadeOutTask?.cancel()
        pendingFadeOutTask = nil
        fadeOut = nil
    }

    private func startCapture(
        bundleIdentifier: String?,
        trackIdentifier: String?,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        clearFadeOut()
        requestedGeneration += 1
        let generation = requestedGeneration
        pendingTrackResetTask?.cancel()
        pendingTrackResetTask = nil
        pendingTrackIdentifier = nil
        isStartingCapture = true
        startingBundleIdentifier = bundleIdentifier
        startingTrackIdentifier = trackIdentifier

        // A new source starts dark until its first measured audio. No old
        // pulse or synthetic breathing is carried into the new capture session.
        isRunning = false
        visualization = .empty
        currentBundleIdentifier = nil
        currentTrackIdentifier = nil

        let updateRelay = MusicAudioUpdateRelay()
        worker.start(
            bundleIdentifier: bundleIdentifier,
            onStarted: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, generation == requestedGeneration else { return }
                    isStartingCapture = false
                    startingBundleIdentifier = nil
                    switch result {
                    case .success:
                        currentBundleIdentifier = bundleIdentifier
                        currentTrackIdentifier = startingTrackIdentifier ?? trackIdentifier
                        startingTrackIdentifier = nil
                        activationState = .active
                        isRunning = true
                        AppSettings.markMusicAudioCaptureGrantedForCurrentBuild()
                        completion(.success(()))
                    case .failure(let error):
                        startingTrackIdentifier = nil
                        activationState = .unavailable(error.localizedDescription)
                        isRunning = false
                        completion(.failure(error))
                    }
                }
            },
            onUpdate: { update in
                updateRelay.submit(update) { @MainActor [weak self] update in
                    guard let self,
                          generation == requestedGeneration,
                          isRunning else { return }
                    apply(update)
                }
            }
        )
    }

    private func apply(_ update: MusicAudioAnalysisWorker.Update) {
        let envelope = update.appearance.envelope
        if envelope.timestamp.isFinite,
           envelope.timestamp != visualization.appearance.envelope.timestamp {
            let age = Foundation.ProcessInfo.processInfo.systemUptime - envelope.timestamp
            DebugLog.shared.write(String(format: "[music-glow] accent age_ms=%.1f peak=%.3f release_ms=%.0f",
                age * 1_000, envelope.peak, envelope.releaseDuration * 1_000))
        }
        visualization = Visualization(appearance: update.appearance, bands: update.bands)
    }

    private func scheduleTrackResetIfNeeded(to trackIdentifier: String?) {
        // Empty metadata commonly appears between two now-playing payloads.
        // Wait for a stable, non-empty identity instead of resetting twice.
        guard let trackIdentifier else { return }
        guard trackIdentifier != currentTrackIdentifier else {
            pendingTrackResetTask?.cancel()
            pendingTrackResetTask = nil
            pendingTrackIdentifier = nil
            return
        }
        guard trackIdentifier != pendingTrackIdentifier else { return }

        pendingTrackResetTask?.cancel()
        pendingTrackIdentifier = trackIdentifier
        let generation = requestedGeneration
        pendingTrackResetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self,
                  self.isRunning,
                  generation == self.requestedGeneration,
                  self.pendingTrackIdentifier == trackIdentifier else { return }

            self.currentTrackIdentifier = trackIdentifier
            self.pendingTrackIdentifier = nil
            self.pendingTrackResetTask = nil
            self.worker.resetAnalysis()
        }
    }

    nonisolated static func trackIdentifier(title: String, artist: String) -> String? {
        let normalizedTitle = normalizedMetadata(title)
        let normalizedArtist = normalizedMetadata(artist)
        guard normalizedTitle != nil || normalizedArtist != nil else { return nil }
        return "\(normalizedTitle ?? "")\u{0}\(normalizedArtist ?? "")"
    }

    nonisolated private static func normalizedMetadata(_ value: String) -> String? {
        let normalized = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

import Combine
import Foundation

/// Converts low-frequency onsets into slow, phrase-level ambient light.
///
/// BPM decides whether the rhythm is dependable and whether to present every
/// second or fourth beat. The physical light curve remains fixed, so the edge
/// follows musical structure without behaving like a fast metronome.
nonisolated struct MusicGlowEnvelope {
    private enum Timing {
        static let attack: Float = 0.05
        static let crest: Float = 0.08
        static let release: Float = 0.65
        // The rendered glow crosses the visibility floor before the numeric
        // 0.78s envelope ends, so 1.15s still leaves a clear pause while
        // allowing a stable two-beat cadence through 102 BPM.
        static let visualCooldown: Float = 1.15
        static let fallbackPeriod: Float = 3
        static let fallbackFadeOut: Float = 0.8
        static let fallbackFadeIn: Float = 1
        static let silenceGrace: Float = 0.65
        static let silenceFade: Float = 0.35
        static let signalRecoveryDebounce: Float = 0.12
        static let signalFadeIn: Float = 0.2
    }

    private(set) var value: Float = 1
    private(set) var reactiveValue: Float = 0
    private(set) var fallbackMix: Float = 1
    private(set) var signalGain: Float = 1
    private(set) var rhythmConfidence: Float = 0
    private(set) var isBeatLocked = false
    private(set) var isSilent = false
    private(set) var estimatedBPM: Float?
    private(set) var pulseDuration = Timing.attack + Timing.crest + Timing.release
    private(set) var detectedOnsetCount = 0
    private(set) var visualBeatStride = 4
    private(set) var visualPulseCount = 0
    private(set) var lastPulsePeak: Float = 0

    private var clock: Float = 0
    private var fluxMean: Float = 0
    private var fluxDeviation: Float = 0
    private var isOnsetArmed = true
    private var onsetSuppressionRemaining: Float = 0
    private var timeSinceOnset: Float?
    private var timeSinceVisualPulse: Float?
    private var recentOnsetIntervals: [Float] = []
    private var recentOnsetStrengths: [Float] = []
    private var hasPresentedPulseForCurrentLock = false
    private var isAccentPhaseAnchored = false
    private var lowConfidenceDuration: Float = 0
    private var silenceDuration: Float = 0
    private var signalDuration: Float = 0
    private var pulseAge: Float?
    private var pulseStartValue: Float = 0
    private var pulsePeak: Float = 0

    mutating func advance(
        bassLevel: Float,
        bassFlux: Float,
        audioLevel: Float = 1,
        hasSignal: Bool,
        minimumFluxBeforeOnset: Float = 1,
        minimumFluxAfterOnset: Float = 1,
        deltaTime: TimeInterval
    ) -> Float {
        let elapsed = Float(min(max(deltaTime, 1.0 / 240.0), 2))
        let level = Self.clamp(bassLevel.isFinite ? bassLevel : 0)
        let flux = Self.clamp(bassFlux.isFinite ? bassFlux : 0)
        let loudness = Self.clamp(audioLevel.isFinite ? audioLevel : 0)
        let fluxBeforeOnset = Self.clamp(
            minimumFluxBeforeOnset.isFinite ? minimumFluxBeforeOnset : 1
        )
        let fluxAfterOnset = Self.clamp(
            minimumFluxAfterOnset.isFinite ? minimumFluxAfterOnset : 1
        )
        clock += elapsed
        onsetSuppressionRemaining = max(onsetSuppressionRemaining - elapsed, 0)

        if let currentTimeSinceOnset = timeSinceOnset {
            timeSinceOnset = currentTimeSinceOnset + elapsed
        }
        if let currentTimeSinceVisualPulse = timeSinceVisualPulse {
            timeSinceVisualPulse = currentTimeSinceVisualPulse + elapsed
        }
        updateAudibility(hasSignal: hasSignal, elapsed: elapsed)

        let onsetThreshold = max(0.085, fluxMean + max(0.045, fluxDeviation * 2.2))
        let rearmThreshold = max(0.025, onsetThreshold * 0.45)
        if !isOnsetArmed,
           min(flux, fluxBeforeOnset) <= rearmThreshold {
            isOnsetArmed = true
        }

        let isOutsideRefractoryPeriod = timeSinceOnset.map { $0 >= 0.16 } ?? true
        let isDistinctOnset = hasSignal
            && onsetSuppressionRemaining == 0
            && isOnsetArmed
            && level >= 0.12
            && loudness >= 0.08
            && flux >= onsetThreshold
            && isOutsideRefractoryPeriod
        if isDistinctOnset {
            isOnsetArmed = false
            let thresholdProgress = Self.clamp(
                (flux - onsetThreshold) / max(1 - onsetThreshold, 0.001)
            )
            let strength = Self.clamp(
                (flux * 0.48)
                    + (level * 0.27)
                    + (loudness * 0.1)
                    + (thresholdProgress * 0.15)
            )
            registerOnset(strength: strength)
        }
        if fluxAfterOnset <= rearmThreshold {
            isOnsetArmed = true
        }

        // Strong transients are winsorized before entering the noise model;
        // otherwise one kick raises its own threshold and hides the next one.
        let baselineSample = min(flux, onsetThreshold)
        let baselineBlend = min(elapsed / 1.8, 1)
        fluxMean += (baselineSample - fluxMean) * baselineBlend
        fluxDeviation += (abs(baselineSample - fluxMean) - fluxDeviation) * baselineBlend

        updateRhythmLock(elapsed: elapsed)
        updateFallbackMix(elapsed: elapsed)

        advancePulse(by: elapsed)
        updateFinalValue()
        return value
    }

    mutating func reset(suppressOnsetsFor duration: Float = 0) {
        value = 1
        reactiveValue = 0
        fallbackMix = 1
        signalGain = 1
        rhythmConfidence = 0
        isBeatLocked = false
        isSilent = false
        estimatedBPM = nil
        pulseDuration = Timing.attack + Timing.crest + Timing.release
        detectedOnsetCount = 0
        visualBeatStride = 4
        visualPulseCount = 0
        lastPulsePeak = 0
        clock = 0
        fluxMean = 0
        fluxDeviation = 0
        isOnsetArmed = true
        onsetSuppressionRemaining = max(duration, 0)
        timeSinceOnset = nil
        timeSinceVisualPulse = nil
        recentOnsetIntervals.removeAll(keepingCapacity: true)
        recentOnsetStrengths.removeAll(keepingCapacity: true)
        hasPresentedPulseForCurrentLock = false
        isAccentPhaseAnchored = false
        lowConfidenceDuration = 0
        silenceDuration = 0
        signalDuration = 0
        pulseAge = nil
        pulseStartValue = 0
        pulsePeak = 0
    }

    /// Drops tempo evidence for a new track without restarting the visual
    /// oscillator. The old pulse can finish and fallback fades in from its
    /// current phase, so metadata changes never create a full-bright jump.
    mutating func resetRhythm(suppressOnsetsFor duration: Float) {
        rhythmConfidence = 0
        isBeatLocked = false
        estimatedBPM = nil
        detectedOnsetCount = 0
        visualBeatStride = 4
        visualPulseCount = 0
        fluxMean = 0
        fluxDeviation = 0
        isOnsetArmed = true
        onsetSuppressionRemaining = max(duration, 0)
        timeSinceOnset = nil
        recentOnsetIntervals.removeAll(keepingCapacity: true)
        recentOnsetStrengths.removeAll(keepingCapacity: true)
        hasPresentedPulseForCurrentLock = false
        isAccentPhaseAnchored = false
        lowConfidenceDuration = 0
    }

    private var estimatedBeatInterval: Float {
        guard let estimatedBPM else { return 0.6 }
        return 60 / estimatedBPM
    }

    private mutating func registerOnset(strength: Float) {
        detectedOnsetCount += 1
        if let interval = timeSinceOnset,
           interval >= 0.22,
           interval <= 2 {
            var normalizedInterval = interval
            while normalizedInterval < 0.333 {
                normalizedInterval *= 2
            }
            while normalizedInterval > 1 {
                normalizedInterval /= 2
            }

            recentOnsetIntervals.append(normalizedInterval)
            if recentOnsetIntervals.count > 8 {
                recentOnsetIntervals.removeFirst()
            }

            let medianInterval = Self.median(recentOnsetIntervals)
            let measuredBPM = 60 / medianInterval
            if let estimatedBPM {
                self.estimatedBPM = estimatedBPM * 0.8 + measuredBPM * 0.2
            } else {
                estimatedBPM = measuredBPM
            }

            let relativeErrors = recentOnsetIntervals.map {
                abs($0 - medianInterval) / max(medianInterval, 0.001)
            }
            let robustError = (Self.median(relativeErrors) * 0.65)
                + ((relativeErrors.reduce(0, +) / Float(relativeErrors.count)) * 0.35)
            let stability = Self.clamp(1 - (robustError / 0.18))
            let evidence = min(Float(recentOnsetIntervals.count) / 4, 1)
            rhythmConfidence = stability * evidence
            if !isBeatLocked,
               recentOnsetIntervals.count >= 3,
               rhythmConfidence >= 0.68 {
                isBeatLocked = true
                lowConfidenceDuration = 0
                hasPresentedPulseForCurrentLock = false
                isAccentPhaseAnchored = false
                updateVisualBeatStride(force: true)
            } else if isBeatLocked {
                updateVisualBeatStride(force: false)
            }
        }

        timeSinceOnset = 0
        recentOnsetStrengths.append(strength)
        // Nine samples retain both accents when the main beat repeats every
        // eight detected onsets, while still adapting within a few seconds.
        if recentOnsetStrengths.count > 9 {
            recentOnsetStrengths.removeFirst()
        }

        guard isBeatLocked else { return }

        let requestedPeak = 0.72 + strength * 0.28
        if let pulseAge,
           pulseAge <= Timing.attack + Timing.crest {
            pulsePeak = max(pulsePeak, requestedPeak)
            lastPulsePeak = pulsePeak
        }

        let targetVisualInterval = max(
            estimatedBeatInterval * Float(visualBeatStride),
            Timing.visualCooldown
        )
        let hasClearedPhysicalCooldown = timeSinceVisualPulse.map {
            $0 >= Timing.visualCooldown
        } ?? true
        guard hasClearedPhysicalCooldown else { return }

        let accent = accentProfile(for: strength)
        if !hasPresentedPulseForCurrentLock {
            let shouldStartFirstPulse = accent.isRepeatedMainAccent
                || accent.isCurrentProvisionalAccent
                || (!accent.hasProvisionalContrast && accent.isAtLeastTypical)
            guard shouldStartFirstPulse else { return }
            startPulse(
                peak: requestedPeak,
                anchorsAccentPhase: accent.isRepeatedMainAccent
            )
            return
        }

        let hasReachedScheduledBeat = timeSinceVisualPulse.map {
            $0 + 0.06 >= targetVisualInterval
        } ?? true
        let accentAnchorLifetime = max(
            targetVisualInterval * 2.25,
            estimatedBeatInterval * 9
        )
        if isAccentPhaseAnchored,
           timeSinceVisualPulse.map({ $0 >= accentAnchorLifetime }) ?? false {
            // If the established accent disappears for more than a full
            // strength-history window, let ordinary beats establish a new
            // phase instead of waiting forever.
            isAccentPhaseAnchored = false
        }

        if accent.isRepeatedMainAccent,
           !isAccentPhaseAnchored || hasReachedScheduledBeat {
            startPulse(peak: requestedPeak, anchorsAccentPhase: true)
        } else if accent.isCurrentProvisionalAccent,
                  !isAccentPhaseAnchored || hasReachedScheduledBeat {
            // The first clearly stronger transient is a better phase candidate
            // than the arbitrary beat on which tempo lock was acquired. It can
            // correct that phase once; repeated accents confirm the anchor.
            startPulse(peak: requestedPeak, anchorsAccentPhase: false)
        } else if !isAccentPhaseAnchored,
                  !accent.hasRepeatedContrast,
                  accent.isAtLeastTypical,
                  hasReachedScheduledBeat {
            // Some recordings have nearly uniform kicks. With no trustworthy
            // accent hierarchy, retain the stable phrase-level cadence.
            startPulse(peak: requestedPeak, anchorsAccentPhase: false)
        }
    }

    private struct AccentProfile {
        let hasProvisionalContrast: Bool
        let hasRepeatedContrast: Bool
        let isCurrentProvisionalAccent: Bool
        let isRepeatedMainAccent: Bool
        let isAtLeastTypical: Bool
    }

    private func accentProfile(for strength: Float) -> AccentProfile {
        let sortedStrengths = recentOnsetStrengths.sorted()
        let baseline = Self.median(sortedStrengths)
        let contrastFloor = max(0.03, baseline * 0.08)
        let recentPeak = sortedStrengths.last ?? strength
        let provisionalSpan = max(recentPeak - baseline, 0)
        let hasProvisionalContrast = sortedStrengths.count >= 4
            && provisionalSpan >= contrastFloor
        let provisionalAccentFloor = baseline + provisionalSpan * 0.55
        let isCurrentProvisionalAccent = hasProvisionalContrast
            && strength + 0.001 >= recentPeak
            && strength >= provisionalAccentFloor

        let repeatedPeak = sortedStrengths.count >= 2
            ? sortedStrengths[sortedStrengths.count - 2]
            : recentPeak
        let repeatedSpan = max(repeatedPeak - baseline, 0)
        let hasRepeatedContrast = sortedStrengths.count >= 5
            && repeatedSpan >= contrastFloor
        let repeatedAccentFloor = baseline + repeatedSpan * 0.55
        let isRepeatedMainAccent = hasRepeatedContrast
            && strength >= repeatedAccentFloor

        let typicalTolerance = max(0.025, baseline * 0.12)
        return AccentProfile(
            hasProvisionalContrast: hasProvisionalContrast,
            hasRepeatedContrast: hasRepeatedContrast,
            isCurrentProvisionalAccent: isCurrentProvisionalAccent,
            isRepeatedMainAccent: isRepeatedMainAccent,
            isAtLeastTypical: strength + typicalTolerance >= baseline
        )
    }

    private mutating func startPulse(peak: Float, anchorsAccentPhase: Bool) {
        let isFirstPulseForLock = !hasPresentedPulseForCurrentLock
        if isFirstPulseForLock {
            // Hand off from the breathing fallback at its current brightness.
            // This keeps the first real accent visible without a mode jump.
            pulseStartValue = signalGain > 0.001
                ? Self.clamp(value / signalGain)
                : reactiveValue
            fallbackMix = 0
        } else {
            pulseStartValue = reactiveValue
        }
        let resolvedPeak = max(peak, pulseStartValue)
        pulsePeak = resolvedPeak
        lastPulsePeak = resolvedPeak
        pulseAge = 0
        timeSinceVisualPulse = 0
        hasPresentedPulseForCurrentLock = true
        isAccentPhaseAnchored = anchorsAccentPhase
        visualPulseCount += 1
    }

    private mutating func updateVisualBeatStride(force: Bool) {
        guard let estimatedBPM else { return }
        let previousStride = visualBeatStride
        if force {
            visualBeatStride = estimatedBPM <= 102 ? 2 : 4
        } else if visualBeatStride == 2, estimatedBPM >= 108 {
            visualBeatStride = 4
        } else if visualBeatStride == 4, estimatedBPM <= 96 {
            visualBeatStride = 2
        }
        if visualBeatStride != previousStride {
            isAccentPhaseAnchored = false
        }
    }

    private mutating func updateAudibility(hasSignal: Bool, elapsed: Float) {
        if hasSignal {
            silenceDuration = 0
            signalDuration += elapsed
            if signalDuration >= Timing.signalRecoveryDebounce {
                isSilent = false
                signalGain = min(signalGain + elapsed / Timing.signalFadeIn, 1)
            }
        } else {
            signalDuration = 0
            silenceDuration += elapsed
            if silenceDuration >= Timing.silenceGrace {
                isSilent = true
                signalGain = max(signalGain - elapsed / Timing.silenceFade, 0)
            }
        }
    }

    private mutating func updateRhythmLock(elapsed: Float) {
        guard isBeatLocked else {
            lowConfidenceDuration = 0
            return
        }

        if rhythmConfidence < 0.35 {
            lowConfidenceDuration += elapsed
        } else {
            lowConfidenceDuration = 0
        }

        let maximumOnsetGap = max(2.2, estimatedBeatInterval * 3)
        let hasTimedOut = timeSinceOnset.map { $0 >= maximumOnsetGap } ?? true
        if hasTimedOut || lowConfidenceDuration >= 2 {
            isBeatLocked = false
            rhythmConfidence = 0
            estimatedBPM = nil
            recentOnsetIntervals.removeAll(keepingCapacity: true)
            recentOnsetStrengths.removeAll(keepingCapacity: true)
            lowConfidenceDuration = 0
            hasPresentedPulseForCurrentLock = false
            isAccentPhaseAnchored = false
        }
    }

    private mutating func updateFallbackMix(elapsed: Float) {
        let target: Float
        if isBeatLocked, !isSilent {
            // Keep the complete breathing glow visible while tempo is locked
            // but the first credible accent is still pending. startPulse()
            // hands off at the current brightness when that accent arrives.
            target = hasPresentedPulseForCurrentLock ? 0 : 1
        } else {
            target = 1
        }
        if target < fallbackMix {
            fallbackMix = max(fallbackMix - elapsed / Timing.fallbackFadeOut, target)
        } else if target > fallbackMix {
            fallbackMix = min(fallbackMix + elapsed / Timing.fallbackFadeIn, target)
        }
    }

    private mutating func advancePulse(by elapsed: Float) {
        guard let currentAge = pulseAge else {
            reactiveValue = 0
            return
        }

        let age = currentAge + elapsed
        pulseAge = age

        if age < Timing.attack {
            let progress = Self.clamp(age / Timing.attack)
            let eased = Self.smoothstep(progress)
            reactiveValue = pulseStartValue + (pulsePeak - pulseStartValue) * eased
            return
        }

        let releaseStart = Timing.attack + Timing.crest
        if age < releaseStart {
            reactiveValue = pulsePeak
            return
        }

        let releaseProgress = Self.clamp((age - releaseStart) / Timing.release)
        reactiveValue = pulsePeak * (1 - Self.smoothstep(releaseProgress))
        if releaseProgress >= 1 {
            reactiveValue = 0
            pulseAge = nil
        }
    }

    private mutating func updateFinalValue() {
        let phase = (clock.truncatingRemainder(dividingBy: Timing.fallbackPeriod))
            / Timing.fallbackPeriod
        let breathingWave = 0.5 + 0.5 * cosf(phase * 2 * .pi)
        let fallbackValue = 0.15 + breathingWave * 0.85
        let mixedValue = (fallbackValue * fallbackMix)
            + (reactiveValue * (1 - fallbackMix))
        let nextValue = Self.clamp(mixedValue * signalGain)
        value = isSilent ? min(value, nextValue) : nextValue
        if value < 0.004 {
            value = 0
        }
    }

    private static func smoothstep(_ value: Float) -> Float {
        value * value * (3 - 2 * value)
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

nonisolated private final class MusicAudioAnalysisWorker: @unchecked Sendable {
    struct Update: Sendable {
        let timestamp: TimeInterval
        let bands: [Float]
        let bassLevel: Float
        let bassFlux: Float
        let audioLevel: Float
        let hasSignal: Bool
        let minimumFluxBeforeOnset: Float
        let minimumFluxAfterOnset: Float
    }

    enum StartResult: @unchecked Sendable {
        case success
        case failure(Error)
    }

    private let capture = NookSystemAudioCapture()
    private let queue = DispatchQueue(
        label: "com.oaimgo.nook.music-audio-analysis",
        qos: .userInitiated
    )
    private var timer: DispatchSourceTimer?
    private var readBuffer = [Float](repeating: 0, count: 4_096)
    private var lastBands = [Float](repeating: 0, count: 4)
    private var pendingBands: [Float]?
    private var pendingBassLevel: Float = 0
    private var pendingBassFlux: Float = 0
    private var pendingAudioLevel: Float = 0
    private var pendingOnsetScore: Float = -1
    private var pendingMinimumBassFluxSeen: Float = 1
    private var pendingMinimumFluxBeforeOnset: Float = 1
    private var pendingMinimumFluxAfterOnset: Float = 1
    private var pendingHasSignal = false
    private var lastPublishTime: TimeInterval = 0

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

            guard let processor = MusicSignalProcessor(sampleRate: capture.sampleRate) else {
                let error = NSError(
                    domain: "com.oaimgo.nook.audio-analysis",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to initialize music frequency analysis."]
                )
                capture.stop()
                onStarted(.failure(error))
                return
            }

            installTimer(processor: processor, onUpdate: onUpdate)
            onStarted(.success)
        }
    }

    func stop() {
        queue.async { [self] in
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        capture.stop()
        lastBands = [Float](repeating: 0, count: 4)
        pendingBands = nil
        pendingBassLevel = 0
        pendingBassFlux = 0
        pendingAudioLevel = 0
        pendingOnsetScore = -1
        pendingMinimumBassFluxSeen = 1
        pendingMinimumFluxBeforeOnset = 1
        pendingMinimumFluxAfterOnset = 1
        pendingHasSignal = false
        lastPublishTime = 0
    }

    private func installTimer(
        processor: MusicSignalProcessor,
        onUpdate: @escaping @Sendable (Update) -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(3))
        lastPublishTime = Foundation.ProcessInfo.processInfo.systemUptime
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            let sampleCount = readBuffer.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Int(self.capture.readSamples(
                    into: baseAddress,
                    capacity: UInt(buffer.count)
                ))
            }
            if sampleCount > 0 {
                readBuffer.withUnsafeBufferPointer { buffer in
                    processor.ingest(UnsafeBufferPointer(rebasing: buffer[..<sampleCount])) { output in
                        self.pendingBands = output.bands
                        self.pendingHasSignal = self.pendingHasSignal || output.hasSignal

                        // Preserve the strongest complete onset feature pair
                        // across the presentation interval. Taking only the
                        // latest FFT frame loses short kicks that land first.
                        let onsetScore = output.bassLevel
                            * output.bassFlux
                            * output.level
                        if onsetScore > self.pendingOnsetScore {
                            self.pendingOnsetScore = onsetScore
                            self.pendingBassLevel = output.bassLevel
                            self.pendingBassFlux = output.bassFlux
                            self.pendingAudioLevel = output.level
                            self.pendingMinimumFluxBeforeOnset = self.pendingMinimumBassFluxSeen
                            self.pendingMinimumFluxAfterOnset = 1
                        } else {
                            self.pendingMinimumFluxAfterOnset = min(
                                self.pendingMinimumFluxAfterOnset,
                                output.bassFlux
                            )
                        }
                        self.pendingMinimumBassFluxSeen = min(
                            self.pendingMinimumBassFluxSeen,
                            output.bassFlux
                        )
                    }
                }
            }

            let now = Foundation.ProcessInfo.processInfo.systemUptime
            guard now - self.lastPublishTime >= 0.03 else { return }
            self.lastPublishTime = now

            let hadAnalysisFrame = self.pendingBands != nil
            if let pendingBands = self.pendingBands {
                self.lastBands = pendingBands
            } else {
                // A source can temporarily stop delivering tap samples. Keep
                // advancing the presentation clock and let stale bars settle.
                self.lastBands = self.lastBands.map { $0 * 0.82 }
            }

            onUpdate(Update(
                timestamp: now,
                bands: self.lastBands,
                bassLevel: hadAnalysisFrame ? self.pendingBassLevel : 0,
                bassFlux: hadAnalysisFrame ? self.pendingBassFlux : 0,
                audioLevel: hadAnalysisFrame ? self.pendingAudioLevel : 0,
                hasSignal: hadAnalysisFrame && self.pendingHasSignal,
                minimumFluxBeforeOnset: hadAnalysisFrame
                    ? self.pendingMinimumFluxBeforeOnset
                    : 0,
                minimumFluxAfterOnset: hadAnalysisFrame
                    ? self.pendingMinimumFluxAfterOnset
                    : 0
            ))
            self.pendingBands = nil
            self.pendingBassLevel = 0
            self.pendingBassFlux = 0
            self.pendingAudioLevel = 0
            self.pendingOnsetScore = -1
            self.pendingMinimumBassFluxSeen = 1
            self.pendingMinimumFluxBeforeOnset = 1
            self.pendingMinimumFluxAfterOnset = 1
            self.pendingHasSignal = false
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
        let glowIntensity: Float
        let bands: [Float]

        static let empty = Visualization(
            glowIntensity: 0,
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

    private let worker = MusicAudioAnalysisWorker()
    private var currentBundleIdentifier: String?
    private var currentTrackIdentifier: String?
    private var isStartingCapture = false
    private var startingBundleIdentifier: String?
    private var startingTrackIdentifier: String?
    private var isExplicitActivationInFlight = false
    private var pendingTrackIdentifier: String?
    private var pendingTrackResetTask: Task<Void, Never>?
    private var requestedGeneration = 0
    private var glowEnvelope = MusicGlowEnvelope()
    private var lastGlowUpdateTime: TimeInterval?

    private init() {}

    var glowIntensity: Float {
        visualization.glowIntensity
    }

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
        guard enabled else {
            // AppStorage remains false until an explicit permission request
            // succeeds. Playback metadata arriving meanwhile must not cancel
            // that request and invalidate its generation.
            guard !isExplicitActivationInFlight else { return }
            if isRunning || isStartingCapture {
                stop()
            }
            return
        }
        guard isPlaying else {
            if isRunning || isStartingCapture {
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

    func stop() {
        requestedGeneration += 1
        pendingTrackResetTask?.cancel()
        pendingTrackResetTask = nil
        pendingTrackIdentifier = nil
        isStartingCapture = false
        startingBundleIdentifier = nil
        startingTrackIdentifier = nil
        isExplicitActivationInFlight = false
        isRunning = false
        visualization = .empty
        glowEnvelope.reset()
        lastGlowUpdateTime = nil
        currentBundleIdentifier = nil
        currentTrackIdentifier = nil
        if activationState == .active || activationState == .requesting {
            activationState = .idle
        }
        worker.stop()
    }

    private func startCapture(
        bundleIdentifier: String?,
        trackIdentifier: String?,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        requestedGeneration += 1
        let generation = requestedGeneration
        pendingTrackResetTask?.cancel()
        pendingTrackResetTask = nil
        pendingTrackIdentifier = nil
        isStartingCapture = true
        startingBundleIdentifier = bundleIdentifier
        startingTrackIdentifier = trackIdentifier

        // A track/source change starts from the familiar breathing fallback.
        // This also covers sources that successfully create an audio tap but
        // do not immediately deliver samples; the previous track's envelope
        // must never remain frozen on screen.
        isRunning = false
        visualization = .empty
        glowEnvelope.reset()
        lastGlowUpdateTime = nil
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
        let elapsed = lastGlowUpdateTime.map { update.timestamp - $0 } ?? (1.0 / 30.0)
        lastGlowUpdateTime = update.timestamp
        let glowIntensity = glowEnvelope.advance(
            bassLevel: update.bassLevel,
            bassFlux: update.bassFlux,
            audioLevel: update.audioLevel,
            hasSignal: update.hasSignal,
            minimumFluxBeforeOnset: update.minimumFluxBeforeOnset,
            minimumFluxAfterOnset: update.minimumFluxAfterOnset,
            deltaTime: elapsed
        )
        visualization = Visualization(
            glowIntensity: glowIntensity,
            bands: update.bands
        )
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
            self.glowEnvelope.resetRhythm(suppressOnsetsFor: 0.25)
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

import Foundation

/// A timestamped light gesture. Sampling it cannot create a beat, restart an
/// animation, or stretch its tail when the main thread misses a frame.
nonisolated struct MusicGlowEnvelope: Equatable, Sendable {
    private(set) var timestamp: TimeInterval = -.infinity
    private(set) var peak: Float = 0
    private(set) var releaseDuration: TimeInterval = 0.65
    private var startValue: Float = 0
    private var releaseSoftness: Float = 0
    private var pacing = ReleasePacing()

    static let attackDuration: TimeInterval = 0.05

    mutating func trigger(_ accent: MusicTransientDetector.Accent) {
        guard accent.timestamp.isFinite, accent.strength.isFinite,
              accent.timestamp > timestamp else { return }
        startValue = value(at: accent.timestamp)
        timestamp = accent.timestamp
        peak = max(startValue, min(max(accent.strength, 0), 1))
        pacing.observe(accent)
        releaseDuration = pacing.duration
        releaseSoftness = pacing.softness
    }

    /// Forget the previous track's pace without changing an in-flight gesture.
    mutating func resetPacing() { pacing = ReleasePacing() }

    func value(at time: TimeInterval) -> Float {
        guard time.isFinite else { return 0 }
        let age = time - timestamp
        guard age >= 0, age < Self.attackDuration + releaseDuration else { return 0 }
        if age < Self.attackDuration {
            let progress = Float(age / Self.attackDuration)
            let eased = progress * progress * (3 - 2 * progress)
            return startValue + (peak - startValue) * eased
        }
        let progress = Float((age - Self.attackDuration) / releaseDuration)
        // Dense gestures retain the original quadratic decay. In a confirmed
        // sparse passage, blend toward a linear tail: the existing visibility
        // mapping otherwise hides most of the extra duration. Both curves fall
        // immediately, without a bright hold, and have a finite end.
        let remaining = 1 - progress
        return peak * remaining * (remaining + releaseSoftness * progress)
    }

    func shifted(by offset: TimeInterval) -> Self {
        var result = self
        result.timestamp += offset
        result.pacing.lastTime = result.pacing.lastTime.map { $0 + offset }
        return result
    }

    /// Animation context, not BPM estimation or beat selection. Repeated sparse
    /// gaps must support a longer tail; one missed hit is insufficient.
    /// State is constant-size and changes only on actual accepted accents.
    private struct ReleasePacing: Equatable, Sendable {
        var lastTime: TimeInterval?
        private var lastStrength: Float = 0
        private var previousGap: TimeInterval?
        private var previousGapStrength: Float = 0
        private var established = false
        private var sparseGapCount = 0
        private var speedupLimit: TimeInterval?
        private(set) var duration: TimeInterval = 0.65

        var softness: Float {
            established ? Float(min(max((duration - 0.4) / 0.7, 0), 1)) : 0
        }

        mutating func observe(_ accent: MusicTransientDetector.Accent) {
            let gap = lastTime.map { accent.timestamp - $0 }
            defer {
                lastTime = accent.timestamp
                lastStrength = accent.strength
            }
            guard let gap else {
                // A descriptive detector interval can seed a short first pulse,
                // but cannot establish a slow passage on its own.
                duration = Self.baselineRelease(for: accent.interval)
                return
            }
            guard gap <= 2.5 else {
                self = Self()
                return
            }
            guard gap >= 0.24 else {
                // A stronger hit replacing a pickup is not a new tempo sample.
                previousGap = nil
                sparseGapCount = 0
                return
            }

            sparseGapCount = Self.release(for: gap) > 0.65 ? min(sparseGapCount + 1, 3) : 0
            let previousDuration = duration
            let baseline = Self.baselineRelease(for: accent.interval)
            // Preserve the established median-based duration for ordinary
            // material. Using every raw short gap would make syncopated songs
            // unnecessarily snappier even when no long tail was active.
            duration = baseline
            if let speedupLimit {
                let supportedLimit = previousGap.map { Self.release(for: min($0, gap)) } ?? speedupLimit
                if baseline <= supportedLimit + 0.025 {
                    self.speedupLimit = nil
                } else {
                    self.speedupLimit = supportedLimit
                    duration = min(duration, supportedLimit)
                }
            }
            if previousDuration > 0.65 {
                // A genuinely long tail must react to the first faster hit.
                // Keep this cap until the detector's five-hit median catches up.
                duration = min(previousDuration, Self.release(for: gap))
                if duration <= 0.65 { speedupLimit = duration }
            }
            // Brightness is not detection confidence: the detector may give
            // alternating instruments/FFT phases different strengths. Require
            // one foreground anchor across the two gaps, not three bright hits.
            let gapStrength = max(lastStrength, accent.strength)
            let credible = max(previousGapStrength, gapStrength) >= 0.45
            if !credible, duration > baseline {
                duration = max(baseline, duration - 0.25)
            }
            if credible, let previousGap {
                let supported = Self.release(for: min(previousGap, gap))
                // Three sparse gaps keep a bright hit from the preceding fast
                // section from lending long tails to subsequent weak decoration.
                if sparseGapCount >= 3, supported > 0.65 {
                    duration = min(supported, previousDuration + 0.25)
                    speedupLimit = nil
                }
                established = true
            }
            previousGap = gap
            previousGapStrength = gapStrength
        }

        private static func release(for interval: TimeInterval) -> TimeInterval {
            min(max(interval * 0.9 - MusicGlowEnvelope.attackDuration, 0.22), 1.5)
        }

        private static func baselineRelease(for interval: TimeInterval?) -> TimeInterval {
            guard let interval, interval.isFinite, interval > 0 else { return 0.65 }
            return min(release(for: interval), 0.65)
        }
    }
}

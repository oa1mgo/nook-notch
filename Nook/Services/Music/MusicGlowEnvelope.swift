import Foundation

/// A timestamped light gesture. Sampling it cannot create a beat, restart an
/// animation, or stretch its tail when the main thread misses a frame.
nonisolated struct MusicGlowEnvelope: Equatable, Sendable {
    private(set) var timestamp: TimeInterval = -.infinity
    private(set) var peak: Float = 0
    private(set) var releaseDuration: TimeInterval = 0.65
    private var startValue: Float = 0

    static let attackDuration: TimeInterval = 0.05

    mutating func trigger(_ accent: MusicTransientDetector.Accent) {
        guard accent.timestamp.isFinite, accent.strength.isFinite,
              accent.timestamp > timestamp else { return }
        startValue = value(at: accent.timestamp)
        timestamp = accent.timestamp
        peak = max(startValue, min(max(accent.strength, 0), 1))
        // Preserve the long 650ms tail for sparse material. Dense music needs
        // darkness before the next real hit, not overlapping full-bright crests.
        releaseDuration = accent.interval.map { min(max($0 * 0.9 - Self.attackDuration, 0.22), 0.65) } ?? 0.65
    }

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
        // Immediate, smooth release instead of a bright hold followed by a
        // slow-start fade. Finite support guarantees a genuinely dark rest.
        return peak * (1 - progress) * (1 - progress)
    }

    func shifted(by offset: TimeInterval) -> Self {
        var result = self
        result.timestamp += offset
        return result
    }
}

import Foundation

/// Composes a quiet, audio-gated ambient floor with the existing accent gesture.
/// Both layers use the same album gradient; composition happens after the accent's
/// visibility curve so the floor really is 18% of the displayed peak.
nonisolated struct MusicGlowAppearance: Equatable, Sendable {
    static let maximumOpacity: Double = 0.95
    static let ambientFraction: Double = 0.18
    private static let attackDuration: TimeInterval = 0.3
    private static let signalGrace: TimeInterval = 0.8
    private static let silenceFade: TimeInterval = 0.5

    private(set) var envelope = MusicGlowEnvelope()
    private var lastSignalTime: TimeInterval?
    private var attackStartTime: TimeInterval = 0
    private var attackStartGain: Double = 0

    mutating func observeSignal(at time: TimeInterval) {
        guard time.isFinite else { return }
        if let lastSignalTime, time <= lastSignalTime { return }
        if lastSignalTime.map({ time - $0 > Self.signalGrace }) ?? true {
            // Resume from the current fade level instead of jumping back to full.
            attackStartGain = ambientGain(at: time)
            attackStartTime = time
        }
        lastSignalTime = time
    }

    mutating func trigger(_ accent: MusicTransientDetector.Accent) {
        envelope.trigger(accent)
    }

    mutating func resetPacing() { envelope.resetPacing() }

    func opacity(at time: TimeInterval) -> Double {
        let base = Self.ambientFraction * ambientGain(at: time)
        let accent = Self.accentVisibility(envelope.value(at: time))
        return Self.maximumOpacity * (base + (1 - base) * accent)
    }

    /// The same production mapping without the ambient layer, for A/B evaluation.
    static func accentOpacity(_ intensity: Float) -> Double {
        maximumOpacity * accentVisibility(intensity)
    }

    private static func accentVisibility(_ intensity: Float) -> Double {
        guard intensity.isFinite else { return 0 }
        let visible = min(max((Double(intensity) - 0.12) / 0.88, 0), 1)
        return visible * visible * (3 - 2 * visible)
    }

    private func ambientGain(at time: TimeInterval) -> Double {
        guard time.isFinite, let lastSignalTime else { return 0 }
        let attack = min(max((time - attackStartTime) / Self.attackDuration, 0), 1)
        let fade = min(max((time - lastSignalTime - Self.signalGrace) / Self.silenceFade, 0), 1)
        let attackGain = attackStartGain + (1 - attackStartGain) * attack * attack * (3 - 2 * attack)
        return attackGain * (1 - fade * fade * (3 - 2 * fade))
    }
}

/// Finishes the currently visible light after playback stops, without keeping
/// capture alive or restarting an accent animation.
nonisolated struct MusicGlowFadeOut: Equatable, Sendable {
    static let duration: TimeInterval = 0.45
    let startTime: TimeInterval
    let startOpacity: Double

    func opacity(at time: TimeInterval) -> Double {
        guard time.isFinite, startTime.isFinite, startOpacity.isFinite else { return 0 }
        let progress = min(max((time - startTime) / Self.duration, 0), 1)
        return min(max(startOpacity, 0), MusicGlowAppearance.maximumOpacity)
            * (1 - progress * progress * (3 - 2 * progress))
    }
}

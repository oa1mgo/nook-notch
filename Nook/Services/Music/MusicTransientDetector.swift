import Foundation

/// Causal accent detection. Tempo is descriptive; it never invents or schedules a hit.
/// All decisions run on consecutive FFT frames, before UI snapshots are coalesced.
nonisolated struct MusicTransientDetector {
    struct Accent: Equatable, Sendable {
        let timestamp: TimeInterval
        let strength: Float
        let interval: TimeInterval?
    }

    private struct Candidate {
        let timestamp: TimeInterval
        let score: Float
        let threshold: Float
        let loudness: Float
        let hasSignal: Bool
    }

    private var previous: Candidate?
    private var precedingScore: Float = 0
    private var mean: Float = 0
    private var deviation: Float = 0
    private var lastTimestamp: TimeInterval?
    private var lastCandidateTime: TimeInterval?
    private var lastAccentTime: TimeInterval?
    private var lastAccentScore: Float = 0
    private var strengths: [(time: TimeInterval, value: Float)] = []
    private var intervals: [TimeInterval] = []

    mutating func reset() { self = Self() }

    mutating func consume(_ frame: MusicSignalProcessor.Output) -> Accent? {
        guard frame.timestamp.isFinite,
              lastTimestamp.map({ frame.timestamp > $0 }) ?? true else { return nil }
        let elapsed = lastTimestamp.map { frame.timestamp - $0 } ?? 0.01
        if elapsed > 0.15 { reset() }
        lastTimestamp = frame.timestamp
        let bands = frame.onsetBands.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
        guard bands.count == 4 else { return nil }

        // Bass is the anchor; body + presence also admit a snare/acoustic attack.
        // Air alone (hi-hats/sibilance) cannot drive a full-notch flash.
        let score = max(bands[0], max(bands[1] * 0.85, bands[2] * 0.55))
            + min(bands[1], bands[2]) * 0.12
        let threshold = max(0.055, mean + max(0.025, deviation * 1.8))
        let candidate = Candidate(timestamp: frame.timestamp, score: score,
            threshold: threshold, loudness: frame.level, hasSignal: frame.hasSignal)

        var accent: Accent?
        if let previous,
           previous.hasSignal, previous.loudness >= 0.035,
           previous.score > precedingScore, previous.score >= score,
           previous.score >= previous.threshold,
           previous.timestamp - (lastCandidateTime ?? -.infinity) >= 0.075 {
            lastCandidateTime = previous.timestamp
            accent = qualify(previous)
        }
        precedingScore = previous?.score ?? 0
        previous = candidate

        // Do not let a single kick raise its own detection threshold.
        let sample = min(score, threshold)
        let blend = Float(1 - exp(-min(elapsed, 0.05) / 0.8))
        deviation += (abs(sample - mean) - deviation) * blend
        mean += (sample - mean) * blend
        return accent
    }

    private mutating func qualify(_ candidate: Candidate) -> Accent? {
        strengths.removeAll { candidate.timestamp - $0.time > 4 }
        let sorted = strengths.map(\.value).sorted()
        // The upper quartile represents recent meaningful hits, not the single
        // loudest outlier. Quieter ghost notes retain their lower prominence.
        let referenceIndex = Int(ceil(Double(max(sorted.count - 1, 0)) * 0.75))
        let reference = sorted.isEmpty ? candidate.score : sorted[referenceIndex]
        strengths.append((candidate.timestamp, candidate.score))
        if strengths.count > 48 { strengths.removeFirst() }
        let relative = candidate.score / max(reference, 0.055)
        guard relative >= 0.42 else { return nil }

        let gap = lastAccentTime.map { candidate.timestamp - $0 }
        // This is only a double-trigger / dense-fill guard (not a beat stride).
        // A 160-BPM kick at 375ms remains eligible, from the first hit onward.
        if let gap, gap < 0.24 {
            // A quiet pickup must not steal the following downbeat. Permit a
            // clearly stronger real attack to replace it, never a roll of peers.
            guard gap >= 0.1, relative >= 0.85,
                  candidate.score >= lastAccentScore * 1.6 else { return nil }
        }
        if let gap, gap < 0.34, relative < 0.85 { return nil }
        if let gap, gap >= 0.24, gap <= 1.8 {
            intervals.append(gap)
            if intervals.count > 5 { intervals.removeFirst() }
        } else if gap.map({ $0 > 1.8 }) ?? false {
            intervals.removeAll(keepingCapacity: true)
        }
        lastAccentTime = candidate.timestamp
        lastAccentScore = candidate.score
        let sortedIntervals = intervals.sorted()
        let interval = sortedIntervals.isEmpty ? nil : sortedIntervals[sortedIntervals.count / 2]
        let prominence = min(max(relative, 0), 1)
        let strength = powf(prominence, 1.6) * (0.8 + min(max(candidate.loudness, 0), 1) * 0.2)
        return Accent(timestamp: candidate.timestamp, strength: strength, interval: interval)
    }
}

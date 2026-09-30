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
        let band: Int
        let score: Float
        let novelty: Float
        let threshold: Float
        let energy: Float
        let contrast: Float
        let loudness: Float
        let hasSignal: Bool
    }

    private struct Lane {
        var previous: Candidate?
        var precedingScore: Float = 0
        var mean: Float = 0
        var deviation: Float = 0
        var lastCandidateTime: TimeInterval?
        var strengths = StrengthReference()
    }

    /// Upper-quartile context, with one observation per attack cluster. A snare
    /// spanning several bands must not count as several votes for its loudness.
    private struct StrengthReference {
        private var hits: [(time: TimeInterval, value: Float)] = []

        mutating func observe(_ value: Float, at time: TimeInterval) -> Float {
            hits.removeAll { time - $0.time > 4 }
            let sorted = hits.map(\.value).sorted()
            let index = Int(ceil(Double(max(sorted.count - 1, 0)) * 0.75))
            let reference = sorted.isEmpty ? value : sorted[index]
            if let last = hits.last, time - last.time < 0.075 {
                hits[hits.count - 1].value = max(last.value, value)
            } else {
                hits.append((time, value))
                if hits.count > 48 { hits.removeFirst() }
            }
            return reference
        }
    }

    private var lanes = [Lane](repeating: Lane(), count: 3)
    private var lastTimestamp: TimeInterval?
    private var lastAccentTime: TimeInterval?
    private var lastAccentEnergy: Float = 0
    private var mixStrengths = StrengthReference()
    private var intervals: [TimeInterval] = []

    mutating func reset() { self = Self() }

    mutating func consume(_ frame: MusicSignalProcessor.Output) -> Accent? {
        guard frame.timestamp.isFinite,
              lastTimestamp.map({ frame.timestamp > $0 }) ?? true else { return nil }
        let elapsed = lastTimestamp.map { frame.timestamp - $0 } ?? 0.01
        if elapsed > 0.15 { reset() }
        lastTimestamp = frame.timestamp
        guard frame.onsetBands.count == 4, frame.onsetEnergies.count == 4,
              frame.onsetImpacts.count == 4, frame.onsetContrasts.count == 4 else { return nil }
        if let lastAccentTime, frame.timestamp - lastAccentTime < 0.07 {
            // Measure the whole leading edge, not only its first partial FFT.
            // Otherwise an equal roll hit can look stronger than the first one.
            lastAccentEnergy = max(lastAccentEnergy, frame.onsetEnergies.prefix(3).map(Self.unit).max() ?? 0)
        }
        var candidates: [Candidate] = []
        // Each instrument range learns its own noise and attack reference.
        // Air alone (hi-hats/sibilance) still cannot drive a full-notch flash.
        for band in lanes.indices {
            let score = Self.unit(frame.onsetImpacts[band])
            let threshold = max(0.025, lanes[band].mean + max(0.015, lanes[band].deviation * 1.8))
            let candidate = Candidate(timestamp: frame.timestamp, band: band, score: score,
                novelty: Self.unit(frame.onsetBands[band]), threshold: threshold,
                energy: Self.unit(frame.onsetEnergies[band]),
                contrast: Self.unit(frame.onsetContrasts[band]),
                loudness: Self.unit(frame.level), hasSignal: frame.hasSignal)
            if let previous = lanes[band].previous,
               previous.hasSignal, previous.loudness >= 0.035,
               previous.score > lanes[band].precedingScore, previous.score >= score,
               previous.score >= previous.threshold,
               previous.contrast >= 0.12,
               previous.timestamp - (lanes[band].lastCandidateTime ?? -.infinity) >= 0.075 {
                lanes[band].lastCandidateTime = previous.timestamp
                candidates.append(previous)
            }
            lanes[band].precedingScore = lanes[band].previous?.score ?? 0
            lanes[band].previous = candidate
            // Do not let a single kick raise its own detection threshold.
            let sample = min(score, threshold)
            let blend = Float(1 - exp(-min(elapsed, 0.05) / 0.8))
            lanes[band].deviation += (abs(sample - lanes[band].mean) - lanes[band].deviation) * blend
            lanes[band].mean += (sample - lanes[band].mean) * blend
        }
        // One mixed attack is one gesture, chosen by actual energy, not by which
        // independently normalized band happens to report the largest fraction.
        for candidate in candidates.sorted(by: { $0.energy > $1.energy }) {
            if let accent = qualify(candidate) { return accent }
        }
        return nil
    }

    private mutating func qualify(_ candidate: Candidate) -> Accent? {
        let band = candidate.band
        // The upper quartile represents recent meaningful hits, not the single
        // loudest outlier. Quieter ghost notes retain their lower prominence.
        let reference = lanes[band].strengths.observe(candidate.novelty, at: candidate.timestamp)
        let relative = candidate.novelty / max(reference, 0.045)
        guard relative >= 0.42 else { return nil }

        let prominence = min(max(relative, 0), 1)
        let mixReference = mixStrengths.observe(candidate.energy, at: candidate.timestamp)
        // A lane can establish that an attack is real without declaring it the
        // main accent of the mix. Soft weighting preserves snare/acoustic hits
        // while small accompaniment changes get a smaller gesture, not a veto.
        let mixProminence = powf(min(candidate.energy / max(mixReference, 0.000_01), 1), 0.35)
        let foreground = min(candidate.score / 0.18, 1)
        let strength = powf(prominence, 1.6) * mixProminence * foreground * (0.8 + candidate.loudness * 0.2)
        // Near-invisible candidates must not consume the cooldown or set animation pace.
        guard strength >= 0.20 else { return nil }

        let gap = lastAccentTime.map { candidate.timestamp - $0 }
        // This is only a double-trigger / dense-fill guard (not a beat stride).
        // A 160-BPM kick at 375ms remains eligible, from the first hit onward.
        if let gap, gap < 0.24 {
            // A quiet pickup must not steal the following downbeat. Permit a
            // clearly stronger real attack to replace it, never a roll of peers.
            guard gap >= 0.1,
                  candidate.energy >= lastAccentEnergy * 1.6 else { return nil }
        }
        if let gap, gap >= 0.24, gap <= 1.8 {
            intervals.append(gap)
            if intervals.count > 5 { intervals.removeFirst() }
        } else if gap.map({ $0 > 1.8 }) ?? false {
            intervals.removeAll(keepingCapacity: true)
        }
        lastAccentTime = candidate.timestamp
        lastAccentEnergy = candidate.energy
        let sortedIntervals = intervals.sorted()
        let interval = sortedIntervals.isEmpty ? nil : sortedIntervals[sortedIntervals.count / 2]
        return Accent(timestamp: candidate.timestamp, strength: strength, interval: interval)
    }

    private static func unit(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

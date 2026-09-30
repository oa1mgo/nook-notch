// Optional baseline adapter for the offline evaluator. Compile with snapshots
// of the 1.4.0 processor/envelope renamed LegacyMusicSignalProcessor/GlowEnvelope.
// Never linked into Nook. See the evaluation recipe in the transient-engine spec.
import Foundation

final class LegacyMusicReviewEngine {
    private let processor: LegacyMusicSignalProcessor
    private var envelope = LegacyMusicGlowEnvelope()
    private var lastTime: TimeInterval = 0
    private var score: Float = -1
    private var bass: Float = 0
    private var flux: Float = 0
    private var level: Float = 0
    private var minimum: Float = 1
    private var before: Float = 1
    private var after: Float = 1
    private var signal = false
    private(set) var value: Float = 1
    private(set) var pulseCount = 0

    init(sampleRate: Double) { processor = LegacyMusicSignalProcessor(sampleRate: sampleRate)! }

    func ingest(_ samples: UnsafeBufferPointer<Float>, at time: TimeInterval) {
        processor.ingest(samples) { output in
            signal = signal || output.hasSignal
            let candidate = output.bassLevel * output.bassFlux * output.level
            if candidate > score {
                score = candidate
                bass = output.bassLevel
                flux = output.bassFlux
                level = output.level
                before = minimum
                after = 1
            } else {
                after = min(after, output.bassFlux)
            }
            minimum = min(minimum, output.bassFlux)
        }
        guard time - lastTime >= 0.03 else { return }
        value = envelope.advance(bassLevel: bass, bassFlux: flux, audioLevel: level,
            hasSignal: signal, minimumFluxBeforeOnset: before, minimumFluxAfterOnset: after,
            deltaTime: time - lastTime)
        pulseCount = envelope.visualPulseCount
        lastTime = time
        score = -1
        bass = 0; flux = 0; level = 0; signal = false
        minimum = 1; before = 1; after = 1
    }
}

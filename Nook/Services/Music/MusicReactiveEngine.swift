import Foundation

/// Shared by live capture, PCM regression tests, and the offline music evaluator.
/// Audio sample time is translated to host time once, independently of UI cadence.
nonisolated final class MusicReactiveEngine {
    private let processor: MusicSignalProcessor
    private let sampleRate: Double
    private var detector = MusicTransientDetector()
    private var sampleCount: Int64 = 0
    private var previousEndTime: TimeInterval?
    private(set) var appearance = MusicGlowAppearance()
    var envelope: MusicGlowEnvelope { appearance.envelope }
    private(set) var bands: [Float] = [0, 0, 0, 0]

    init?(sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate >= 16_000,
              let processor = MusicSignalProcessor(sampleRate: sampleRate) else { return nil }
        self.processor = processor
        self.sampleRate = sampleRate
    }

    func resetAnalysis() {
        processor.reset(sampleRate: sampleRate)
        detector.reset()
        sampleCount = 0
        previousEndTime = nil
        appearance.resetPacing()
        // Keep the current appearance continuous. Ambient light still expires
        // without new audible samples; resetting metadata never emits light.
    }

    func ingest(
        _ samples: UnsafeBufferPointer<Float>,
        endingAt endTime: TimeInterval,
        now: TimeInterval,
        onAccent: (MusicTransientDetector.Accent) -> Void = { _ in }
    ) {
        guard !samples.isEmpty, endTime.isFinite, now.isFinite else { return }
        guard now - endTime <= 0.12 else {
            resetAnalysis()
            return
        }
        let startTime = endTime - Double(samples.count) / sampleRate
        if let previousEndTime, abs(startTime - previousEndTime) > 0.025 {
            resetAnalysis()
        }
        let offset = startTime - Double(sampleCount) / sampleRate
        sampleCount += Int64(samples.count)
        previousEndTime = endTime
        processor.ingest(samples) { frame in
            bands = frame.bands
            if frame.hasSignal {
                appearance.observeSignal(at: frame.timestamp + offset)
            }
            guard let event = detector.consume(frame) else { return }
            let accent = MusicTransientDetector.Accent(timestamp: event.timestamp + offset,
                strength: event.strength, interval: event.interval)
            guard now - accent.timestamp <= 0.12 else { return }
            appearance.trigger(accent)
            onAccent(accent)
        }
    }
}

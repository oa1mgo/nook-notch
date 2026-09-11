import XCTest
@testable import Nook

final class MusicSignalProcessorTests: XCTestCase {
    private let frameDuration = 1.0 / 120.0

    func testSilenceProducesNoLevelSpectrumOrBassOnset() throws {
        let processor = try XCTUnwrap(MusicSignalProcessor(sampleRate: 48_000))
        let outputs = process([Float](repeating: 0, count: 48_000), with: processor)

        let last = try XCTUnwrap(outputs.last)
        XCTAssertEqual(last.level, 0, accuracy: 0.001)
        XCTAssertEqual(last.bassLevel, 0, accuracy: 0.001)
        XCTAssertEqual(last.bassFlux, 0, accuracy: 0.001)
        XCTAssertFalse(last.hasSignal)
        XCTAssertTrue(last.bands.allSatisfy { $0 == 0 })
    }

    func testSpectrumSeparatesBassAndHighFrequencies() throws {
        let bassProcessor = try XCTUnwrap(MusicSignalProcessor(sampleRate: 48_000))
        let highProcessor = try XCTUnwrap(MusicSignalProcessor(sampleRate: 48_000))

        let bass = sineWave(frequency: 90, duration: 1.2, amplitude: 0.25)
        let high = sineWave(frequency: 3_200, duration: 1.2, amplitude: 0.25)
        let bassOutput = try XCTUnwrap(process(bass, with: bassProcessor).last)
        let highOutput = try XCTUnwrap(process(high, with: highProcessor).last)

        XCTAssertGreaterThan(bassOutput.bands[0], bassOutput.bands[3] + 0.2)
        XCTAssertGreaterThan(highOutput.bands[3], highOutput.bands[0] + 0.2)
    }

    func testBassFluxIgnoresFirstFrameAndSettlesForSteadyTone() throws {
        let processor = try XCTUnwrap(MusicSignalProcessor(sampleRate: 48_000))
        let outputs = process(
            sineWave(frequency: 90, duration: 1.2, amplitude: 0.25),
            with: processor
        )

        XCTAssertEqual(try XCTUnwrap(outputs.first).bassFlux, 0, accuracy: 0.000_1)
        let settledFlux = try XCTUnwrap(outputs.suffix(8).map(\.bassFlux).max())
        XCTAssertLessThan(settledFlux, 0.03)
    }

    func testBassFluxRespondsToLowFrequencyAmplitudeRise() throws {
        let processor = try XCTUnwrap(MusicSignalProcessor(sampleRate: 48_000))
        let samples = amplitudeSteppedSine(
            frequency: 90,
            duration: 1,
            stepTime: 0.4,
            lowAmplitude: 0.025,
            highAmplitude: 0.3
        )
        let outputs = process(samples, with: processor)

        let strongestOnset = try XCTUnwrap(outputs.max {
            ($0.bassLevel * $0.bassFlux) < ($1.bassLevel * $1.bassFlux)
        })
        XCTAssertGreaterThan(strongestOnset.bassFlux, 0.35)
        XCTAssertGreaterThan(strongestOnset.bassLevel, 0.25)
    }

    func testResetDoesNotCreateSyntheticFirstOnset() throws {
        let processor = try XCTUnwrap(MusicSignalProcessor(sampleRate: 48_000))
        let tone = sineWave(frequency: 90, duration: 0.2, amplitude: 0.25)
        _ = process(tone, with: processor)

        processor.reset(sampleRate: 48_000)
        let outputsAfterReset = process(tone, with: processor)

        XCTAssertEqual(
            try XCTUnwrap(outputsAfterReset.first).bassFlux,
            0,
            accuracy: 0.000_1
        )
    }

    func testTrackIdentityIgnoresCaseAndWhitespaceButDetectsNewSong() {
        let first = MusicAudioAnalyzer.trackIdentifier(
            title: "  First   Song ",
            artist: "The Artist"
        )
        let formattingOnly = MusicAudioAnalyzer.trackIdentifier(
            title: "first song",
            artist: " the artist  "
        )
        let next = MusicAudioAnalyzer.trackIdentifier(
            title: "Second Song",
            artist: "The Artist"
        )

        XCTAssertEqual(first, formattingOnly)
        XCTAssertNotEqual(first, next)
        XCTAssertNil(MusicAudioAnalyzer.trackIdentifier(title: " ", artist: ""))
    }

    private func process(
        _ samples: [Float],
        with processor: MusicSignalProcessor,
        chunkSize: Int = 512
    ) -> [MusicSignalProcessor.Output] {
        var outputs: [MusicSignalProcessor.Output] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            samples.withUnsafeBufferPointer { buffer in
                processor.ingest(UnsafeBufferPointer(rebasing: buffer[offset..<end])) {
                    outputs.append($0)
                }
            }
            offset = end
        }
        return outputs
    }

    private func sineWave(
        frequency: Double,
        duration: Double,
        amplitude: Double,
        sampleRate: Double = 48_000
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            return Float(sin(2 * .pi * frequency * time) * amplitude)
        }
    }

    private func amplitudeSteppedSine(
        frequency: Double,
        duration: Double,
        stepTime: Double,
        lowAmplitude: Double,
        highAmplitude: Double,
        sampleRate: Double = 48_000
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let amplitude = time < stepTime ? lowAmplitude : highAmplitude
            return Float(sin(2 * .pi * frequency * time) * amplitude)
        }
    }

}

import XCTest
@testable import Nook

final class MusicReactiveEngineTests: XCTestCase {
    private let rate = 48_000.0

    func testRegularKicksRespondFromFirstBeatAtSeveralTempos() throws {
        for bpm in [80.0, 120, 160] {
            let times = (0..<12).map { 0.4 + Double($0) * 60 / bpm }
            let events = try analyze(percussion(times: times, duration: times.last! + 1))
            assertMatches(events, times: times, context: "\(bpm) BPM")
        }
    }

    func testSyncopatedHitsAndTempoChangeDoNotWaitForBeatLock() throws {
        let times = [0.4, 1.15, 1.65, 2.4, 2.9, 3.275, 3.65, 4.025, 4.4, 5.15]
        assertMatches(try analyze(percussion(times: times, duration: 6.3)), times: times)
    }

    func testWaltzAccentsAreNotForcedIntoFourBeatStride() throws {
        let times = (0..<6).map { 0.4 + Double($0) * 1.5 }
        var samples = percussion(times: times, duration: 10)
        let ghosts = (0..<18).filter { !$0.isMultiple(of: 3) }.map { 0.4 + Double($0) * 0.5 }
        add(&samples, percussion(times: ghosts, duration: 10, amplitude: 0.055))
        let events = try analyze(samples)
        for time in times {
            XCTAssertTrue(events.contains { $0.timestamp >= time && $0.timestamp - time < 0.07 }, "Missing waltz accent \(time)")
        }
        XCTAssertLessThan(events.count, times.count + 4)
    }

    func testHiHatsDoNotStealKickTiming() throws {
        let kicks = (0..<12).map { 0.4 + Double($0) * 0.5 }
        var samples = percussion(times: kicks, duration: 7)
        let hats = (0..<48).map { 0.4 + Double($0) * 0.125 }
        add(&samples, percussion(times: hats, duration: 7, frequency: 6_000, amplitude: 0.18, decay: 0.012))
        assertMatches(try analyze(samples), times: kicks)
    }

    func testMidrangePercussionWorksWithoutSubBass() throws {
        let times = (0..<10).map { 0.4 + Double($0) * 0.5 }
        assertMatches(try analyze(percussion(times: times, duration: 6, frequency: 350)), times: times)
    }

    func testWeakPickupCannotBlockFollowingStrongDownbeat() throws {
        var samples = percussion(times: [0.4, 1.28, 2.16], duration: 3)
        add(&samples, percussion(times: [1.1, 1.98], duration: 3, amplitude: 0.2))
        let events = try analyze(samples)
        for time in [0.4, 1.28, 2.16] {
            XCTAssertTrue(events.contains { $0.timestamp >= time && $0.timestamp - time < 0.07 }, "Missing downbeat \(time): \(events)")
        }
    }

    func testDenseRollDoesNotGenerateFullBrightnessStrobe() throws {
        let times = (0..<40).map { 0.4 + Double($0) * 0.08 }
        let events = try analyze(percussion(times: times, duration: 4, decay: 0.012))
        XCTAssertLessThan(events.count, 15)
        for (a, b) in zip(events, events.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.timestamp - a.timestamp, 0.23)
        }
    }

    func testActualSampleRatesKeepTimingAndOnsetsStable() throws {
        for sampleRate in [44_100.0, 96_000.0] {
            let engine = try XCTUnwrap(MusicReactiveEngine(sampleRate: sampleRate))
            let count = Int(sampleRate * 2)
            let times = [0.4, 0.9, 1.4]
            let samples = (0..<count).map { index -> Float in
                let time = Double(index) / sampleRate
                var value = 0.0
                for start in times {
                    let age = time - start
                    if age >= 0 && age < 0.24 {
                        value += 0.4 * exp(-age / 0.055) * sin(2 * .pi * 80 * age)
                    }
                }
                return Float(value)
            }
            var events: [MusicTransientDetector.Accent] = []
            for index in stride(from: 0, to: count, by: 512) {
                let end = min(index + 512, count)
                let time = Double(end) / sampleRate
                samples.withUnsafeBufferPointer {
                    engine.ingest(UnsafeBufferPointer(rebasing: $0[index..<end]), endingAt: time, now: time) { events.append($0) }
                }
            }
            assertMatches(events, times: times, context: "\(sampleRate) Hz")
        }
    }

    func testSustainedToneAndVibratoDoNotBecomeBeats() throws {
        var phase: Double = 0
        let samples = (0..<Int(rate * 6)).map { index -> Float in
            let t = Double(index) / rate
            phase += 2 * .pi * (220 + 8 * sin(2 * .pi * 5 * t)) / rate
            let fade = min(t / 0.5, 1)
            return Float(sin(phase) * 0.2 * fade)
        }
        let events = try analyze(samples)
        XCTAssertTrue(events.filter { $0.timestamp > 0.8 }.isEmpty, "Vibrato generated \(events)")
    }

    func testQuietAndLoudVersionsKeepSameTiming() throws {
        let times = (0..<10).map { 0.4 + Double($0) * 0.5 }
        for amplitude in [0.015, 0.45] {
            assertMatches(try analyze(percussion(times: times, duration: 6, amplitude: amplitude)), times: times)
        }
    }

    func testCaptureChunkSizeDoesNotChangeDetectedTimes() throws {
        let samples = percussion(times: [0.4, 0.9, 1.4, 2.15, 2.65], duration: 4)
        let reference = try analyze(samples, chunks: [256])
        let batched = try analyze(samples, chunks: [1_024, 2_048, 512, 137])
        XCTAssertEqual(reference.count, batched.count)
        for (a, b) in zip(reference, batched) {
            XCTAssertEqual(a.timestamp, b.timestamp, accuracy: 1.0 / rate)
            XCTAssertEqual(a.strength, b.strength, accuracy: 0.001)
        }
    }

    func testSilenceHasNoPeriodicFallback() throws {
        let engine = try XCTUnwrap(MusicReactiveEngine(sampleRate: rate))
        let silence = [Float](repeating: 0, count: Int(rate * 5))
        let events = analyze(silence, engine: engine)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(engine.envelope.value(at: 5), 0)
        XCTAssertTrue(engine.bands.allSatisfy { $0 == 0 })
    }

    func testStaleCaptureDoesNotReplayBeats() throws {
        let engine = try XCTUnwrap(MusicReactiveEngine(sampleRate: rate))
        let samples = percussion(times: [0.1], duration: 0.3)
        var events: [MusicTransientDetector.Accent] = []
        samples.withUnsafeBufferPointer {
            engine.ingest($0, endingAt: 0.3, now: 2) { events.append($0) }
        }
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(engine.envelope.value(at: 2), 0)
        let resumed = analyze(percussion(times: [0.4], duration: 1), engine: engine, offset: 2)
        assertMatches(resumed, times: [2.4])
    }

    func testAnalysisResetDoesNotCreateFlashAndAdaptsToQuietNewTrack() throws {
        let engine = try XCTUnwrap(MusicReactiveEngine(sampleRate: rate))
        _ = analyze(percussion(times: [0.3], duration: 0.45), engine: engine)
        let before = engine.envelope.value(at: 0.45)
        engine.resetAnalysis()
        XCTAssertEqual(engine.envelope.value(at: 0.45), before)
        let events = analyze(percussion(times: [0.4, 0.9], duration: 1.4, amplitude: 0.02), engine: engine, offset: 1)
        assertMatches(events, times: [1.4, 1.9])
    }

    func testPulsePeaksAt50msAndFinishesBeforeNextDenseHit() {
        var envelope = MusicGlowEnvelope()
        envelope.trigger(.init(timestamp: 10, strength: 0.9, interval: 0.5))
        XCTAssertEqual(envelope.value(at: 10), 0)
        XCTAssertEqual(envelope.value(at: 10.05), 0.9, accuracy: 0.001)
        XCTAssertLessThan(envelope.value(at: 10.2), 0.5)
        XCTAssertEqual(envelope.value(at: 10.46), 0)
        XCTAssertEqual(envelope.value(at: 11), 0)
        envelope.trigger(.init(timestamp: 12, strength: 1, interval: 1.5))
        XCTAssertEqual(envelope.releaseDuration, 0.65, accuracy: 0.000_1)
        XCTAssertGreaterThan(envelope.value(at: 12.4), 0)
        XCTAssertEqual(envelope.value(at: 12.71), 0)
    }

    func testMissedUIFramesDoNotRestartEnvelopeOrExtendIt() {
        var envelope = MusicGlowEnvelope()
        envelope.trigger(.init(timestamp: 10, strength: 1, interval: 0.5))
        let realtime = stride(from: 10.0, through: 10.5, by: 1.0 / 60).map { envelope.value(at: $0) }
        XCTAssertEqual(envelope.value(at: 10.3), realtime[18], accuracy: 0.001)
        XCTAssertEqual(envelope.value(at: 20), 0)
        XCTAssertEqual(envelope.value(at: 20.1), 0)
    }

    func testInvalidSamplesDoNotPoisonFollowingAudio() throws {
        var samples = percussion(times: [0.4, 0.9], duration: 1.5)
        samples[0] = .nan
        samples[16] = .infinity
        let events = try analyze(samples)
        assertMatches(events, times: [0.4, 0.9])
        XCTAssertTrue(events.allSatisfy { $0.strength.isFinite })
    }

    private func assertMatches(_ events: [MusicTransientDetector.Accent], times: [Double], context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(events.count, times.count, "\(context): \(events.map(\.timestamp))", file: file, line: line)
        for time in times {
            XCTAssertTrue(events.contains { $0.timestamp >= time && $0.timestamp - time < 0.07 }, "\(context): missing hit at \(time), events \(events.map(\.timestamp))", file: file, line: line)
        }
    }

    private func analyze(_ samples: [Float], chunks: [Int] = [512]) throws -> [MusicTransientDetector.Accent] {
        analyze(samples, engine: try XCTUnwrap(MusicReactiveEngine(sampleRate: rate)), chunks: chunks)
    }

    private func analyze(_ samples: [Float], engine: MusicReactiveEngine, chunks: [Int] = [512], offset: Double = 0) -> [MusicTransientDetector.Accent] {
        var result: [MusicTransientDetector.Accent] = []
        var index = 0
        var block = 0
        while index < samples.count {
            let end = min(index + chunks[block % chunks.count], samples.count)
            let time = offset + Double(end) / rate
            samples.withUnsafeBufferPointer {
                engine.ingest(UnsafeBufferPointer(rebasing: $0[index..<end]), endingAt: time, now: time) { result.append($0) }
            }
            index = end
            block += 1
        }
        return result
    }

    private func percussion(times: [Double], duration: Double, frequency: Double = 80, amplitude: Double = 0.4, decay: Double = 0.055) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(duration * rate))
        for time in times {
            let start = Int(time * rate)
            for index in 0..<Int(rate * 0.24) where start + index < samples.count {
                let age = Double(index) / rate
                // Hard excitation + exponentially decaying, pitched drum body.
                samples[start + index] += Float(amplitude * exp(-age / decay) * sin(2 * .pi * frequency * age))
            }
        }
        return samples
    }

    private func add(_ target: inout [Float], _ source: [Float]) {
        for index in target.indices { target[index] += source[index] }
    }
}

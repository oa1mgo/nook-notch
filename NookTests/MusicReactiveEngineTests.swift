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
        XCTAssertEqual(engine.appearance.opacity(at: 5), 0)
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
        XCTAssertEqual(engine.appearance.opacity(at: 2), 0)
        let resumed = analyze(percussion(times: [0.4], duration: 1), engine: engine, offset: 2)
        assertMatches(resumed, times: [2.4])
    }

    func testAnalysisResetDoesNotCreateFlashAndAdaptsToQuietNewTrack() throws {
        let engine = try XCTUnwrap(MusicReactiveEngine(sampleRate: rate))
        _ = analyze(percussion(times: [0.3], duration: 0.45), engine: engine)
        let before = engine.envelope.value(at: 0.45)
        let appearanceBefore = engine.appearance
        engine.resetAnalysis()
        XCTAssertEqual(engine.envelope.value(at: 0.45), before)
        XCTAssertEqual(engine.appearance, appearanceBefore)
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

    func testSustainedPCMProducesBaseWithoutBeatsAndSilenceExtinguishesIt() throws {
        let engine = try XCTUnwrap(MusicReactiveEngine(sampleRate: rate))
        let tone = (0..<Int(rate * 3)).map { index -> Float in
            let time = Double(index) / rate
            return Float(0.2 * min(time / 0.5, 1) * sin(2 * .pi * 220 * time))
        }
        let events = analyze(tone, engine: engine)
        XCTAssertTrue(events.filter { $0.timestamp > 0.8 }.isEmpty)
        XCTAssertEqual(engine.appearance.opacity(at: 3),
            MusicGlowAppearance.maximumOpacity * MusicGlowAppearance.ambientFraction, accuracy: 0.000_1)
        _ = analyze([Float](repeating: 0, count: Int(rate * 2)), engine: engine, offset: 3)
        XCTAssertEqual(engine.appearance.opacity(at: 5), 0)
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

    func testQuietDifferentInstrumentPickupDoesNotStealKick() throws {
        let kicks = (0..<8).map { 0.6 + Double($0) * 0.75 }
        var samples = percussion(times: kicks, duration: 7)
        add(&samples, percussion(times: kicks.map { $0 - 0.16 }, duration: 7,
            frequency: 350, amplitude: 0.045, decay: 0.035))
        let events = try analyze(samples)
        for time in kicks {
            XCTAssertTrue(events.contains { $0.timestamp >= time && $0.timestamp - time < 0.07 },
                "Different-instrument pickup stole kick at \(time): \(events)")
        }
    }

    func testKickAndSnareKeepIndependentStrengthReferences() throws {
        let kicks = (0..<8).map { 0.4 + Double($0) * 0.6 }
        let snares = kicks.map { $0 + 0.3 }
        var samples = percussion(times: kicks, duration: 6)
        add(&samples, percussion(times: snares, duration: 6,
            frequency: 1_100, amplitude: 0.18, decay: 0.035))
        assertMatches(try analyze(samples), times: (kicks + snares).sorted())
    }

    func testQuietNewBandOnSustainedBassDoesNotBecomeFullAccent() throws {
        var samples = sustainedBass(duration: 6, amplitude: 0.22)
        let decorations = (0..<8).map { 1.0 + Double($0) * 0.5 }
        add(&samples, percussion(times: decorations, duration: 6,
            frequency: 350, amplitude: 0.025, decay: 0.035))
        let events = try analyze(samples).filter { $0.timestamp > 0.8 }
        XCTAssertTrue(events.allSatisfy { $0.strength < 0.45 }, "Quiet decoration was promoted: \(events)")
    }

    func testAudibleKicksRemainDetectableOverSustainedBass() throws {
        let kicks = (0..<8).map { 1.0 + Double($0) * 0.5 }
        var samples = sustainedBass(duration: 6, amplitude: 0.22)
        add(&samples, percussion(times: kicks, duration: 6, frequency: 90, amplitude: 0.18))
        assertMatches(try analyze(samples).filter { $0.timestamp > 0.8 }, times: kicks)
    }

    func testSmoothBassTremoloDoesNotMasqueradeAsPercussion() throws {
        let samples = (0..<Int(rate * 6)).map { index -> Float in
            let time = Double(index) / rate
            let amplitude = 0.18 + 0.08 * sin(2 * .pi * 3 * time)
            return Float(amplitude * min(time / 0.5, 1) * sin(2 * .pi * 90 * time))
        }
        let events = try analyze(samples).filter { $0.timestamp > 0.8 }
        XCTAssertTrue(events.isEmpty, "Smooth bass modulation generated \(events)")
    }

    func testKickSnareAndHatsInSustainedMixPreserveMainAttacks() throws {
        let kicks = (0..<8).map { 0.8 + Double($0) * 0.6 }
        let snares = kicks.map { $0 + 0.3 }
        var samples = sustainedBass(duration: 6, amplitude: 0.10)
        add(&samples, sweptKicks(times: kicks, duration: 6))
        add(&samples, snareHits(times: snares, duration: 6))
        let hats = (0..<32).map { 0.8 + Double($0) * 0.15 }
        add(&samples, percussion(times: hats, duration: 6,
            frequency: 6_000, amplitude: 0.10, decay: 0.012))
        assertMatches(try analyze(samples).filter { $0.timestamp > 0.7 }, times: (kicks + snares).sorted())
    }

    func testLongPitchSweptKicksDoNotRetriggerOnTheirTails() throws {
        let kicks = (0..<8).map { 0.4 + Double($0) * 0.75 }
        assertMatches(try analyze(sweptKicks(times: kicks, duration: 7)), times: kicks)
    }

    func testPickupReplacementIsStableAcrossFFTAlignments() throws {
        for offset in [0.0, 0.003, 0.007] {
            let kicks = (0..<5).map { 0.6 + offset + Double($0) * 0.65 }
            var samples = percussion(times: kicks, duration: 4)
            add(&samples, percussion(times: kicks.map { $0 - 0.16 }, duration: 4,
                frequency: 350, amplitude: 0.045, decay: 0.035))
            let events = try analyze(samples, chunks: [137, 512, 1_024])
            for time in kicks {
                XCTAssertTrue(events.contains { $0.timestamp >= time && $0.timestamp - time < 0.07 },
                    "Missing kick at \(time), alignment \(offset): \(events)")
            }
        }
    }

    func testMelodicPitchGlidesDoNotBecomeRepeatedDrumHits() throws {
        var phase = 0.0
        let samples = (0..<Int(rate * 6)).map { index -> Float in
            let time = Double(index) / rate
            let frequency = 220 + 75 * sin(2 * .pi * 0.7 * time)
            phase += 2 * .pi * frequency / rate
            return Float(0.18 * min(time / 0.5, 1) * sin(phase))
        }
        XCTAssertTrue(try analyze(samples).filter { $0.timestamp > 0.8 }.isEmpty)
    }

    private func sweptKicks(times: [Double], duration: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(duration * rate))
        for start in times {
            var phase = 0.0
            for index in 0..<Int(rate * 0.6) {
                let target = Int(start * rate) + index
                guard target < samples.count else { break }
                let age = Double(index) / rate
                phase += 2 * .pi * (48 + 105 * exp(-age / 0.032)) / rate
                let tailFade = min((0.6 - age) / 0.04, 1)
                samples[target] += Float(0.4 * exp(-age / 0.12) * sin(phase) * tailFade)
            }
        }
        return samples
    }

    private func snareHits(times: [Double], duration: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(duration * rate))
        var seed: UInt64 = 0x4e6f6f6b
        for start in times {
            var filteredNoise = 0.0
            for index in 0..<Int(rate * 0.24) {
                let target = Int(start * rate) + index
                guard target < samples.count else { break }
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let noise = Double(seed >> 32) / Double(UInt32.max) * 2 - 1
                filteredNoise += (noise - filteredNoise) * 0.3
                let age = Double(index) / rate
                let tailFade = min((0.24 - age) / 0.02, 1)
                samples[target] += Float((filteredNoise * 0.65 + sin(2 * .pi * 185 * age) * 0.16)
                    * exp(-age / 0.045) * tailFade)
            }
        }
        return samples
    }

    private func sustainedBass(duration: Double, amplitude: Double) -> [Float] {
        (0..<Int(rate * duration)).map { index -> Float in
            let time = Double(index) / rate
            return Float(amplitude * min(time / 0.5, 1) * sin(2 * .pi * 70 * time))
        }
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

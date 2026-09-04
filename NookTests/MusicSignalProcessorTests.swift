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

    func testMusicGlowRequiresLevelFluxAndSignalTogether() {
        var envelope = MusicGlowEnvelope()

        _ = envelope.advance(
            bassLevel: 1,
            bassFlux: 0,
            hasSignal: true,
            deltaTime: frameDuration
        )
        _ = envelope.advance(
            bassLevel: 0,
            bassFlux: 1,
            hasSignal: true,
            deltaTime: frameDuration
        )
        _ = envelope.advance(
            bassLevel: 1,
            bassFlux: 1,
            hasSignal: false,
            deltaTime: frameDuration
        )
        XCTAssertEqual(envelope.detectedOnsetCount, 0)

        _ = envelope.advance(
            bassLevel: 0.8,
            bassFlux: 0.8,
            hasSignal: true,
            deltaTime: frameDuration
        )
        XCTAssertEqual(envelope.detectedOnsetCount, 1)
    }

    func testMusicGlowRejectsRelativeBassRiseBelowAbsoluteNoiseFloor() {
        var envelope = MusicGlowEnvelope()
        _ = envelope.advance(
            bassLevel: 0.9,
            bassFlux: 1,
            audioLevel: 0.02,
            hasSignal: true,
            deltaTime: frameDuration
        )

        XCTAssertEqual(envelope.detectedOnsetCount, 0)
    }

    func testBatchedFluxValleyKeepsItsOrderAroundCandidate() {
        var valleyAfterPeak = MusicGlowEnvelope()
        feedAccent(into: &valleyAfterPeak, bassLevel: 0.8, bassFlux: 0.8)
        advanceWithoutRearming(into: &valleyAfterPeak, duration: 0.2)
        let initialCount = valleyAfterPeak.detectedOnsetCount

        _ = valleyAfterPeak.advance(
            bassLevel: 0.8,
            bassFlux: 0.8,
            audioLevel: 0.8,
            hasSignal: true,
            minimumFluxBeforeOnset: 1,
            minimumFluxAfterOnset: 0,
            deltaTime: frameDuration
        )
        XCTAssertEqual(valleyAfterPeak.detectedOnsetCount, initialCount)
        feedAccent(into: &valleyAfterPeak, bassLevel: 0.8, bassFlux: 0.8)
        XCTAssertEqual(valleyAfterPeak.detectedOnsetCount, initialCount + 1)

        var valleyBeforePeak = MusicGlowEnvelope()
        feedAccent(into: &valleyBeforePeak, bassLevel: 0.8, bassFlux: 0.8)
        advanceWithoutRearming(into: &valleyBeforePeak, duration: 0.2)
        _ = valleyBeforePeak.advance(
            bassLevel: 0.8,
            bassFlux: 0.8,
            audioLevel: 0.8,
            hasSignal: true,
            minimumFluxBeforeOnset: 0,
            minimumFluxAfterOnset: 1,
            deltaTime: frameDuration
        )
        XCTAssertEqual(valleyBeforePeak.detectedOnsetCount, 2)
    }

    func testStableRhythmLocksOnlyAfterEnoughEvidence() throws {
        var envelope = MusicGlowEnvelope()

        feedRegularOnsets(into: &envelope, interval: 0.5, count: 3)
        XCTAssertFalse(envelope.isBeatLocked)
        XCTAssertEqual(envelope.visualPulseCount, 0)

        feedRegularOnsets(into: &envelope, interval: 0.5, count: 5)
        XCTAssertTrue(envelope.isBeatLocked)
        XCTAssertEqual(try XCTUnwrap(envelope.estimatedBPM), 120, accuracy: 2)
        XCTAssertGreaterThanOrEqual(envelope.rhythmConfidence, 0.75)
    }

    func testIrregularOnsetsStayOnFallbackBreathing() {
        var envelope = MusicGlowEnvelope()
        feedOnsets(
            into: &envelope,
            intervals: [0.36, 0.85, 0.49, 0.72, 0.41, 0.95, 0.56]
        )

        XCTAssertFalse(envelope.isBeatLocked)
        XCTAssertLessThan(envelope.rhythmConfidence, 0.55)
        XCTAssertGreaterThan(envelope.fallbackMix, 0.95)
        XCTAssertEqual(envelope.visualPulseCount, 0)
    }

    func testFastTempoIsMeasuredButVisualPulsesStayPhraseLevel() throws {
        var envelope = MusicGlowEnvelope()
        let pulseTimes = feedRegularOnsetsCapturingPulseTimes(
            into: &envelope,
            interval: 0.375,
            count: 24
        )

        XCTAssertEqual(try XCTUnwrap(envelope.estimatedBPM), 160, accuracy: 3)
        XCTAssertGreaterThanOrEqual(pulseTimes.count, 4)
        XCTAssertLessThan(pulseTimes.count, 10)
        for (earlier, later) in zip(pulseTimes, pulseTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, 1.24)
        }
    }

    func testVisualCadenceStaysOnEvenBeatStride() throws {
        var mediumTempo = MusicGlowEnvelope()
        let mediumPulseTimes = feedRegularOnsetsCapturingPulseTimes(
            into: &mediumTempo,
            interval: 0.5,
            count: 16
        )
        XCTAssertEqual(try XCTUnwrap(mediumTempo.estimatedBPM), 120, accuracy: 2)
        XCTAssertEqual(mediumTempo.visualBeatStride, 4)
        XCTAssertGreaterThanOrEqual(mediumPulseTimes.count, 4)
        for (earlier, later) in zip(mediumPulseTimes, mediumPulseTimes.dropFirst()) {
            XCTAssertEqual(later - earlier, 2, accuracy: 0.03)
        }

        var slowerTempo = MusicGlowEnvelope()
        feedOnsets(
            into: &slowerTempo,
            intervals: [0.625, 0.617, 0.633, 0.62, 0.63, 0.618, 0.632]
        )
        XCTAssertEqual(try XCTUnwrap(slowerTempo.estimatedBPM), 96, accuracy: 2)
        XCTAssertEqual(slowerTempo.visualBeatStride, 2)

        var cooldownBoundaryTempo = MusicGlowEnvelope()
        let boundaryInterval = 60.0 / 102.0
        let boundaryPulseTimes = feedRegularOnsetsCapturingPulseTimes(
            into: &cooldownBoundaryTempo,
            interval: boundaryInterval,
            count: 16
        )
        XCTAssertEqual(cooldownBoundaryTempo.visualBeatStride, 2)
        XCTAssertGreaterThanOrEqual(boundaryPulseTimes.count, 4)
        for (earlier, later) in zip(boundaryPulseTimes, boundaryPulseTimes.dropFirst()) {
            XCTAssertEqual(later - earlier, boundaryInterval * 2, accuracy: 0.04)
        }
    }

    func testWeakEligibleBeatWaitsForNextMainAccent() {
        var envelope = MusicGlowEnvelope()
        feedRegularOnsets(
            into: &envelope,
            interval: 0.5,
            count: 8,
            bassLevel: 1,
            bassFlux: 1
        )
        let pulseCountAfterLock = envelope.visualPulseCount

        for _ in 0..<3 {
            advanceToNextAccent(
                in: &envelope,
                interval: 0.5,
                bassLevel: 1,
                bassFlux: 1
            )
        }
        advanceToNextAccent(
            in: &envelope,
            interval: 0.5,
            bassLevel: 0.3,
            bassFlux: 0.3
        )
        XCTAssertEqual(envelope.visualPulseCount, pulseCountAfterLock)

        advanceToNextAccent(
            in: &envelope,
            interval: 0.5,
            bassLevel: 1,
            bassFlux: 1
        )
        XCTAssertEqual(envelope.visualPulseCount, pulseCountAfterLock + 1)
    }

    func testFallbackRemainsVisibleWhileFirstMainAccentIsPending() {
        var envelope = MusicGlowEnvelope()
        feedAccent(into: &envelope, bassLevel: 1, bassFlux: 1)
        for _ in 0..<3 {
            advanceToNextAccent(
                in: &envelope,
                interval: 0.5,
                bassLevel: 0.45,
                bassFlux: 0.45
            )
        }

        XCTAssertTrue(envelope.isBeatLocked)
        XCTAssertEqual(envelope.visualPulseCount, 0)

        var values: [Float] = []
        for _ in 0..<48 {
            advanceBackgroundFrame(into: &envelope)
            values.append(envelope.value)
        }
        XCTAssertEqual(envelope.visualPulseCount, 0)
        XCTAssertGreaterThanOrEqual(envelope.fallbackMix, 0.99)
        XCTAssertGreaterThan(values.min() ?? 0, 0.12)

        for _ in 0..<11 {
            advanceBackgroundFrame(into: &envelope)
        }
        let valueBeforeHandoff = envelope.value
        feedAccent(into: &envelope, bassLevel: 1, bassFlux: 1)
        XCTAssertEqual(envelope.visualPulseCount, 1)
        XCTAssertGreaterThanOrEqual(envelope.value, valueBeforeHandoff)
        XCTAssertLessThan(abs(envelope.value - valueBeforeHandoff), 0.06)
    }

    func testFirstPulseCanWaitEightBeatsForRepeatedMainAccent() {
        var envelope = MusicGlowEnvelope()
        feedAccent(into: &envelope, bassLevel: 1, bassFlux: 1)
        for _ in 0..<7 {
            advanceToNextAccent(
                in: &envelope,
                interval: 0.5,
                bassLevel: 0.45,
                bassFlux: 0.45
            )
        }

        XCTAssertTrue(envelope.isBeatLocked)
        XCTAssertEqual(envelope.visualPulseCount, 0)
        XCTAssertGreaterThanOrEqual(envelope.fallbackMix, 0.99)

        advanceToNextAccent(
            in: &envelope,
            interval: 0.5,
            bassLevel: 1,
            bassFlux: 1
        )
        XCTAssertEqual(envelope.visualPulseCount, 1)
    }

    func testProminentAccentCorrectsVisualPhaseBeforeScheduledPulse() {
        var envelope = MusicGlowEnvelope()
        feedRegularOnsets(
            into: &envelope,
            interval: 0.5,
            count: 4,
            bassLevel: 0.45,
            bassFlux: 0.45
        )
        let pulseCountAfterLock = envelope.visualPulseCount
        XCTAssertEqual(pulseCountAfterLock, 1)

        for _ in 0..<2 {
            advanceToNextAccent(
                in: &envelope,
                interval: 0.5,
                bassLevel: 0.45,
                bassFlux: 0.45
            )
        }
        XCTAssertEqual(envelope.visualPulseCount, pulseCountAfterLock)

        advanceToNextAccent(
            in: &envelope,
            interval: 0.5,
            bassLevel: 1,
            bassFlux: 1
        )
        XCTAssertEqual(envelope.visualPulseCount, pulseCountAfterLock + 1)

        advanceToNextAccent(
            in: &envelope,
            interval: 0.5,
            bassLevel: 0.45,
            bassFlux: 0.45
        )
        XCTAssertEqual(envelope.visualPulseCount, pulseCountAfterLock + 1)
    }

    func testScheduledOrdinaryBeatWaitsForFollowingRepeatedMainAccent() {
        var envelope = MusicGlowEnvelope()
        feedAccent(into: &envelope, bassLevel: 1, bassFlux: 1)
        for _ in 0..<3 {
            advanceToNextAccent(
                in: &envelope,
                interval: 0.5,
                bassLevel: 0.45,
                bassFlux: 0.45
            )
        }
        advanceToNextAccent(
            in: &envelope,
            interval: 0.5,
            bassLevel: 1,
            bassFlux: 1
        )
        let pulseCountAfterMainAccent = envelope.visualPulseCount
        XCTAssertEqual(pulseCountAfterMainAccent, 1)

        for _ in 0..<4 {
            advanceToNextAccent(
                in: &envelope,
                interval: 0.5,
                bassLevel: 0.45,
                bassFlux: 0.45
            )
        }
        XCTAssertEqual(envelope.visualPulseCount, pulseCountAfterMainAccent)

        advanceToNextAccent(
            in: &envelope,
            interval: 0.5,
            bassLevel: 1,
            bassFlux: 1
        )
        XCTAssertEqual(envelope.visualPulseCount, pulseCountAfterMainAccent + 1)
    }

    func testConfirmedMainAccentCanRepeatEveryEightBeatsWithoutOrdinaryBeatStealingPhase() {
        var envelope = MusicGlowEnvelope()
        feedAccent(into: &envelope, bassLevel: 1, bassFlux: 1)
        for _ in 0..<3 {
            advanceToNextAccent(
                in: &envelope,
                interval: 0.5,
                bassLevel: 0.45,
                bassFlux: 0.45
            )
        }
        advanceToNextAccent(
            in: &envelope,
            interval: 0.5,
            bassLevel: 1,
            bassFlux: 1
        )
        let pulseCountAfterMainAccent = envelope.visualPulseCount
        XCTAssertEqual(pulseCountAfterMainAccent, 1)

        for _ in 0..<7 {
            advanceToNextAccent(
                in: &envelope,
                interval: 0.5,
                bassLevel: 0.45,
                bassFlux: 0.45
            )
        }
        XCTAssertEqual(envelope.visualPulseCount, pulseCountAfterMainAccent)

        advanceToNextAccent(
            in: &envelope,
            interval: 0.5,
            bassLevel: 1,
            bassFlux: 1
        )
        XCTAssertEqual(envelope.visualPulseCount, pulseCountAfterMainAccent + 1)
    }

    func testPulseAnimationDurationDoesNotSpeedUpWithBPM() {
        var slowEnvelope = MusicGlowEnvelope()
        feedRegularOnsets(into: &slowEnvelope, interval: 0.75, count: 8)

        var fastEnvelope = MusicGlowEnvelope()
        feedRegularOnsets(into: &fastEnvelope, interval: 0.375, count: 8)

        XCTAssertEqual(slowEnvelope.pulseDuration, fastEnvelope.pulseDuration, accuracy: 0.001)
        XCTAssertEqual(slowEnvelope.pulseDuration, 0.78, accuracy: 0.001)
        XCTAssertLessThan(fastEnvelope.visualPulseCount, fastEnvelope.detectedOnsetCount)
    }

    func testPulseReachesPeakBy50MillisecondsAndKeepsSlowRelease() {
        var envelope = MusicGlowEnvelope()
        feedRegularOnsets(into: &envelope, interval: 0.5, count: 8)
        let peak = envelope.lastPulsePeak

        XCTAssertGreaterThan(peak, 0)
        XCTAssertLessThan(envelope.reactiveValue, peak * 0.1)

        advanceBackground(into: &envelope, duration: 0.04)
        XCTAssertEqual(envelope.reactiveValue, peak, accuracy: 0.01)

        advanceBackground(into: &envelope, duration: 0.07)
        XCTAssertEqual(envelope.reactiveValue, peak, accuracy: 0.01)

        advanceBackground(into: &envelope, duration: 0.34)
        XCTAssertGreaterThan(envelope.reactiveValue, peak * 0.45)
        XCTAssertLessThan(envelope.reactiveValue, peak * 0.58)

        advanceBackground(into: &envelope, duration: 0.33)
        XCTAssertEqual(envelope.reactiveValue, 0, accuracy: 0.001)
    }

    func testAccentStrengthChangesPeakButNotAnimationSpeed() {
        var weakEnvelope = MusicGlowEnvelope()
        var strongEnvelope = MusicGlowEnvelope()
        feedRegularOnsets(
            into: &weakEnvelope,
            interval: 0.5,
            count: 8,
            bassLevel: 0.5,
            bassFlux: 0.5
        )
        feedRegularOnsets(
            into: &strongEnvelope,
            interval: 0.5,
            count: 8,
            bassLevel: 1,
            bassFlux: 1
        )

        XCTAssertGreaterThan(strongEnvelope.lastPulsePeak, weakEnvelope.lastPulsePeak + 0.1)
        XCTAssertEqual(weakEnvelope.pulseDuration, strongEnvelope.pulseDuration, accuracy: 0.001)

        advanceBackground(into: &weakEnvelope, duration: 1)
        advanceBackground(into: &strongEnvelope, duration: 1)
        XCTAssertEqual(weakEnvelope.reactiveValue, 0, accuracy: 0.001)
        XCTAssertEqual(strongEnvelope.reactiveValue, 0, accuracy: 0.001)
    }

    func testLostRhythmCrossfadesBackToFallbackWithoutModeJump() {
        var envelope = MusicGlowEnvelope()
        feedRegularOnsets(into: &envelope, interval: 0.5, count: 8)
        XCTAssertTrue(envelope.isBeatLocked)
        XCTAssertEqual(envelope.fallbackMix, 0, accuracy: 0.02)

        for _ in 0..<480 where envelope.isBeatLocked {
            advanceBackgroundFrame(into: &envelope)
        }
        XCTAssertFalse(envelope.isBeatLocked)

        var mixes: [Float] = [envelope.fallbackMix]
        for _ in 0..<120 {
            advanceBackgroundFrame(into: &envelope)
            mixes.append(envelope.fallbackMix)
        }

        XCTAssertTrue(zip(mixes, mixes.dropFirst()).allSatisfy { $1 >= $0 })
        let largestStep = zip(mixes, mixes.dropFirst()).map { $1 - $0 }.max() ?? 0
        XCTAssertLessThan(largestStep, 0.02)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(mixes.last), 0.99)
    }

    func testMissingAudioHeartbeatFadesOutAndNeverRestartsFallback() {
        var envelope = MusicGlowEnvelope()
        feedRegularOnsets(into: &envelope, interval: 0.5, count: 4)
        advanceBackground(into: &envelope, duration: 0.22)
        let pulseCount = envelope.visualPulseCount

        let firstSilentFrame = envelope.advance(
            bassLevel: 0,
            bassFlux: 0,
            hasSignal: false,
            deltaTime: frameDuration
        )
        XCTAssertGreaterThan(firstSilentFrame, 0)

        var valuesAfterFade: [Float] = []
        for frame in 0..<504 {
            let value = envelope.advance(
                bassLevel: 0,
                bassFlux: 0,
                hasSignal: false,
                deltaTime: frameDuration
            )
            if frame >= 132 {
                valuesAfterFade.append(value)
            }
        }

        XCTAssertTrue(envelope.isSilent)
        XCTAssertEqual(envelope.signalGain, 0, accuracy: 0.001)
        XCTAssertEqual(envelope.visualPulseCount, pulseCount)
        XCTAssertTrue(valuesAfterFade.allSatisfy { $0 == 0 })
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

    func testTrackResetPreservesPresentationAndSuppressesQueuedOnset() {
        var envelope = MusicGlowEnvelope()
        feedRegularOnsets(into: &envelope, interval: 0.5, count: 8)
        advanceBackground(into: &envelope, duration: 1)
        let valueBeforeReset = envelope.value

        envelope.resetRhythm(suppressOnsetsFor: 0.25)
        XCTAssertEqual(envelope.value, valueBeforeReset, accuracy: 0.000_1)
        XCTAssertFalse(envelope.isBeatLocked)

        feedAccent(into: &envelope, bassLevel: 1, bassFlux: 1)
        XCTAssertEqual(envelope.detectedOnsetCount, 0)
        XCTAssertLessThan(abs(envelope.value - valueBeforeReset), 0.03)
    }

    func testTrackResetPreservesPhysicalPulseCooldown() {
        var envelope = MusicGlowEnvelope()
        feedRegularOnsets(into: &envelope, interval: 0.5, count: 4)
        XCTAssertEqual(envelope.visualPulseCount, 1)

        envelope.resetRhythm(suppressOnsetsFor: 0)
        feedRegularOnsets(into: &envelope, interval: 0.25, count: 4)
        XCTAssertTrue(envelope.isBeatLocked)
        XCTAssertEqual(envelope.visualPulseCount, 0)

        advanceToNextAccent(
            in: &envelope,
            interval: 0.25,
            bassLevel: 0.8,
            bassFlux: 0.8
        )
        XCTAssertEqual(envelope.visualPulseCount, 0)

        advanceToNextAccent(
            in: &envelope,
            interval: 0.25,
            bassLevel: 0.8,
            bassFlux: 0.8
        )
        XCTAssertEqual(envelope.visualPulseCount, 1)
    }

    func testRelockDoesNotReuseStaleAccentStrengths() {
        var envelope = MusicGlowEnvelope()
        feedAccent(into: &envelope, bassLevel: 1, bassFlux: 1)
        for _ in 0..<3 {
            advanceToNextAccent(
                in: &envelope,
                interval: 0.5,
                bassLevel: 0.45,
                bassFlux: 0.45
            )
        }
        advanceToNextAccent(
            in: &envelope,
            interval: 0.5,
            bassLevel: 1,
            bassFlux: 1
        )
        let pulseCountBeforeLoss = envelope.visualPulseCount

        advanceBackground(into: &envelope, duration: 2.5)
        XCTAssertFalse(envelope.isBeatLocked)

        feedRegularOnsets(
            into: &envelope,
            interval: 0.5,
            count: 4,
            bassLevel: 0.45,
            bassFlux: 0.45
        )
        XCTAssertTrue(envelope.isBeatLocked)
        XCTAssertEqual(envelope.visualPulseCount, pulseCountBeforeLoss + 1)
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

    private func feedRegularOnsets(
        into envelope: inout MusicGlowEnvelope,
        interval: TimeInterval,
        count: Int,
        bassLevel: Float = 0.8,
        bassFlux: Float = 0.8
    ) {
        guard count > 0 else { return }
        feedOnsets(
            into: &envelope,
            intervals: [TimeInterval](repeating: interval, count: count - 1),
            bassLevel: bassLevel,
            bassFlux: bassFlux
        )
    }

    private func feedOnsets(
        into envelope: inout MusicGlowEnvelope,
        intervals: [TimeInterval],
        bassLevel: Float = 0.8,
        bassFlux: Float = 0.8
    ) {
        feedAccent(into: &envelope, bassLevel: bassLevel, bassFlux: bassFlux)
        for interval in intervals {
            let frameCount = max(Int((interval / frameDuration).rounded()), 1)
            for _ in 0..<(frameCount - 1) {
                advanceBackgroundFrame(into: &envelope)
            }
            feedAccent(into: &envelope, bassLevel: bassLevel, bassFlux: bassFlux)
        }
    }

    private func feedRegularOnsetsCapturingPulseTimes(
        into envelope: inout MusicGlowEnvelope,
        interval: TimeInterval,
        count: Int
    ) -> [TimeInterval] {
        guard count > 0 else { return [] }
        let frameCount = max(Int((interval / frameDuration).rounded()), 1)
        var elapsed: TimeInterval = 0
        var previousPulseCount = envelope.visualPulseCount
        var pulseTimes: [TimeInterval] = []

        for onsetIndex in 0..<count {
            if onsetIndex > 0 {
                for _ in 0..<(frameCount - 1) {
                    advanceBackgroundFrame(into: &envelope)
                    elapsed += frameDuration
                }
            }
            feedAccent(into: &envelope, bassLevel: 0.8, bassFlux: 0.8)
            elapsed += frameDuration
            if envelope.visualPulseCount > previousPulseCount {
                pulseTimes.append(elapsed)
                previousPulseCount = envelope.visualPulseCount
            }
        }
        return pulseTimes
    }

    private func advanceToNextAccent(
        in envelope: inout MusicGlowEnvelope,
        interval: TimeInterval,
        bassLevel: Float,
        bassFlux: Float
    ) {
        let frameCount = max(Int((interval / frameDuration).rounded()), 1)
        for _ in 0..<(frameCount - 1) {
            advanceBackgroundFrame(into: &envelope)
        }
        feedAccent(into: &envelope, bassLevel: bassLevel, bassFlux: bassFlux)
    }

    private func feedAccent(
        into envelope: inout MusicGlowEnvelope,
        bassLevel: Float,
        bassFlux: Float
    ) {
        _ = envelope.advance(
            bassLevel: bassLevel,
            bassFlux: bassFlux,
            audioLevel: bassLevel,
            hasSignal: true,
            deltaTime: frameDuration
        )
    }

    private func advanceBackground(
        into envelope: inout MusicGlowEnvelope,
        duration: TimeInterval
    ) {
        let frameCount = Int((duration / frameDuration).rounded())
        for _ in 0..<frameCount {
            advanceBackgroundFrame(into: &envelope)
        }
    }

    private func advanceWithoutRearming(
        into envelope: inout MusicGlowEnvelope,
        duration: TimeInterval
    ) {
        let frameCount = Int((duration / frameDuration).rounded())
        for _ in 0..<frameCount {
            _ = envelope.advance(
                bassLevel: 0,
                bassFlux: 0.2,
                audioLevel: 0.3,
                hasSignal: true,
                minimumFluxBeforeOnset: 1,
                minimumFluxAfterOnset: 1,
                deltaTime: frameDuration
            )
        }
    }

    private func advanceBackgroundFrame(into envelope: inout MusicGlowEnvelope) {
        _ = envelope.advance(
            bassLevel: 0.04,
            bassFlux: 0,
            audioLevel: 0.3,
            hasSignal: true,
            deltaTime: frameDuration
        )
    }
}

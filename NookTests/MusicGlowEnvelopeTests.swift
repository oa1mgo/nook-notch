import XCTest
@testable import Nook

final class MusicGlowEnvelopeTests: XCTestCase {
    func testEstablishedSlowPassageHasVisibleTailBeyondOldLimit() {
        let envelope = settled(interval: 1.5)
        XCTAssertGreaterThan(envelope.releaseDuration, 1.2)
        XCTAssertEqual(envelope.value(at: envelope.timestamp + 0.05), 1, accuracy: 0.000_1)
        XCTAssertGreaterThan(visibility(envelope, age: 0.85), 0.15)
        XCTAssertGreaterThan(visibility(envelope, age: 1), 0.04)
        XCTAssertEqual(visibility(envelope, age: 1.4), 0)
    }

    func testDensePassageKeepsExistingAttackAndQuadraticRelease() {
        for interval in [0.3, 0.375, 0.5] {
            let envelope = settled(interval: interval)
            let duration = max(0.22, interval * 0.9 - 0.05)
            XCTAssertEqual(envelope.releaseDuration, duration, accuracy: 0.000_1)
            for progress in [0.0, 0.25, 0.5, 0.75, 1] {
                XCTAssertEqual(envelope.value(at: envelope.timestamp + 0.05 + duration * progress),
                    Float((1 - progress) * (1 - progress)), accuracy: 0.000_1)
            }
            XCTAssertEqual(envelope.value(at: envelope.timestamp + interval), 0)
        }
    }

    func testReleaseStartsImmediatelyAndFallsMonotonicallyToBase() {
        for interval in [0.375, 0.75, 1, 1.5, 2.2] {
            let envelope = settled(interval: interval)
            XCTAssertLessThan(envelope.value(at: envelope.timestamp + 0.06), 1)
            var previous: Float = 1
            for age in stride(from: 0.05, through: 2, by: 0.005) {
                let value = envelope.value(at: envelope.timestamp + age)
                XCTAssertLessThanOrEqual(value, previous + 0.000_1)
                XCTAssertGreaterThanOrEqual(value, 0)
                previous = value
            }
            XCTAssertEqual(previous, 0)
        }
    }

    func testSingleMissedAccentDoesNotLengthenRelease() {
        var envelope = settled(interval: 0.5)
        let before = envelope.releaseDuration
        // The detector's rolling median already rejects one missing hit. The
        // animation's new raw-gap context must not reinterpret it as a slowdown.
        envelope.trigger(.init(timestamp: envelope.timestamp + 1, strength: 1, interval: 0.5))
        XCTAssertEqual(envelope.releaseDuration, before, accuracy: 0.000_1)
        envelope.trigger(.init(timestamp: envelope.timestamp + 0.5, strength: 1, interval: 0.5))
        XCTAssertEqual(envelope.releaseDuration, before, accuracy: 0.000_1)
    }

    func testSlowdownRequiresRepeatedEvidenceAndLengthensInBoundedSteps() {
        var envelope = settled(interval: 0.5)
        var previous = envelope.releaseDuration
        for index in 0..<6 {
            // Deliberately stale metadata: use the actual local accent spacing.
            envelope.trigger(.init(timestamp: envelope.timestamp + 1.5, strength: 1, interval: 0.5))
            if index == 0 { XCTAssertEqual(envelope.releaseDuration, previous, accuracy: 0.000_1) }
            XCTAssertGreaterThanOrEqual(envelope.releaseDuration + 0.000_1, previous)
            XCTAssertLessThanOrEqual(envelope.releaseDuration - previous, 0.250_1)
            previous = envelope.releaseDuration
        }
        XCTAssertGreaterThan(envelope.releaseDuration, 1.2)
    }

    func testSpeedupShortensFirstNewGestureDespiteStaleSlowMedian() {
        var envelope = settled(interval: 1.5)
        let time = envelope.timestamp + 0.375
        let before = envelope.value(at: time)
        envelope.trigger(.init(timestamp: time, strength: 1, interval: 1.5))
        XCTAssertEqual(envelope.value(at: time), before, accuracy: 0.000_1)
        XCTAssertEqual(envelope.value(at: time + 0.05), 1, accuracy: 0.000_1)
        XCTAssertLessThan(envelope.releaseDuration, 0.3)
        XCTAssertEqual(envelope.value(at: time + 0.375), 0)
        // The following hit must not bounce back to 650ms while the median lags.
        envelope.trigger(.init(timestamp: time + 0.375, strength: 1, interval: 1.5))
        XCTAssertLessThan(envelope.releaseDuration, 0.3)
    }

    func testWeakSparseDecorationsCannotEstablishLongRelease() {
        var envelope = settled(interval: 0.5)
        for _ in 0..<8 {
            envelope.trigger(.init(timestamp: envelope.timestamp + 1.5, strength: 0.3, interval: 1.5))
            XCTAssertLessThanOrEqual(envelope.releaseDuration, 0.65)
        }
    }

    func testUnknownPaceDoesNotAssumeLongTailFromOneInterval() {
        var envelope = MusicGlowEnvelope()
        envelope.trigger(.init(timestamp: 10, strength: 1, interval: 2))
        XCTAssertEqual(envelope.releaseDuration, 0.65, accuracy: 0.000_1)
        XCTAssertEqual(envelope.value(at: 10.71), 0)
    }

    func testVerySparseMusicIsBoundedAndLongBreakForgetsOldPace() {
        var envelope = settled(interval: 2.2)
        XCTAssertGreaterThan(envelope.releaseDuration, 1.2)
        XCTAssertLessThanOrEqual(envelope.releaseDuration, 1.5)
        XCTAssertEqual(envelope.value(at: envelope.timestamp + 1.56), 0)
        envelope.trigger(.init(timestamp: envelope.timestamp + 4, strength: 1, interval: nil))
        XCTAssertEqual(envelope.releaseDuration, 0.65, accuracy: 0.000_1)
    }

    func testInvalidIntervalsAndOutOfOrderAccentsCannotPoisonAnimation() {
        for interval in [Double.nan, .infinity, -.infinity, -1, 0] {
            var envelope = MusicGlowEnvelope()
            envelope.trigger(.init(timestamp: 10, strength: 1, interval: interval))
            XCTAssertTrue(envelope.releaseDuration.isFinite)
            XCTAssertEqual(envelope.value(at: 10.05), 1, accuracy: 0.000_1)
            XCTAssertEqual(envelope.value(at: 12), 0)
            let before = envelope
            for time in [9, 10, .nan, .infinity] {
                envelope.trigger(.init(timestamp: time, strength: 1, interval: 1.5))
                XCTAssertEqual(envelope, before)
            }
        }
    }

    func testLongTailSamplingAndClockShiftCannotChangeItsLifetime() {
        let envelope = settled(interval: 1.5)
        let shifted = envelope.shifted(by: 100)
        for age in [0.025, 0.05, 0.5, 0.9, 1.3, 3] {
            XCTAssertEqual(envelope.value(at: envelope.timestamp + age),
                shifted.value(at: shifted.timestamp + age), accuracy: 0.000_1)
        }
        XCTAssertEqual(envelope.value(at: .nan), 0)
        XCTAssertEqual(envelope.value(at: .infinity), 0)
    }

    func testPacingResetPreservesTailButDoesNotLeakIntoNextTrack() {
        var envelope = settled(interval: 1.5)
        let previous = envelope
        envelope.resetPacing()
        for age in stride(from: 0.1, through: 1.6, by: 0.01) {
            XCTAssertEqual(envelope.value(at: envelope.timestamp + age),
                previous.value(at: previous.timestamp + age))
        }
        let time = envelope.timestamp + 0.3
        let before = envelope.value(at: time)
        envelope.trigger(.init(timestamp: time, strength: 1, interval: nil))
        XCTAssertEqual(envelope.releaseDuration, 0.65, accuracy: 0.000_1)
        XCTAssertEqual(envelope.value(at: time), before, accuracy: 0.000_1)
    }

    func testClockShiftAlsoPreservesPacingOfFollowingAccent() {
        var envelope = settled(interval: 1.5)
        var shifted = envelope.shifted(by: 100)
        envelope.trigger(.init(timestamp: envelope.timestamp + 1.5, strength: 0.8, interval: 1.5))
        shifted.trigger(.init(timestamp: shifted.timestamp + 1.5, strength: 0.8, interval: 1.5))
        XCTAssertEqual(envelope.releaseDuration, shifted.releaseDuration, accuracy: 0.000_1)
        for age in [0.025, 0.05, 0.5, 0.9, 1.3, 3] {
            XCTAssertEqual(envelope.value(at: envelope.timestamp + age),
                shifted.value(at: shifted.timestamp + age), accuracy: 0.000_1)
        }
    }

    func testAlternatingShortAndLongGapsDoNotCreateLongBrightPlateaus() {
        var envelope = settled(interval: 0.4)
        for index in 0..<12 {
            let gap = index.isMultiple(of: 2) ? 1.2 : 0.4
            envelope.trigger(.init(timestamp: envelope.timestamp + gap, strength: 1, interval: 1.2))
            XCTAssertLessThanOrEqual(envelope.releaseDuration, 0.65)
        }
    }

    func testOrdinarySyncopationKeepsExistingMedianBasedDuration() {
        var envelope = settled(interval: 0.5)
        for gap in [0.28, 0.72, 0.32, 0.68, 0.5, 0.4, 0.6] {
            envelope.trigger(.init(timestamp: envelope.timestamp + gap, strength: 0.8, interval: 0.5))
            XCTAssertEqual(envelope.releaseDuration, 0.4, accuracy: 0.000_1)
        }
    }

    func testAlternatingBrightnessStillLearnsAConsistentlySlowPassage() {
        var envelope = MusicGlowEnvelope()
        for index in 0..<9 {
            envelope.trigger(.init(timestamp: 10 + Double(index) * 1.5,
                strength: index.isMultiple(of: 3) ? 0.9 : 0.25, interval: 1.5))
        }
        XCTAssertGreaterThan(envelope.releaseDuration, 1.2)
    }

    func testSpeedupGuardReleasesWhenMusicSettlesAtAModeratePace() {
        var envelope = settled(interval: 1.5)
        envelope.trigger(.init(timestamp: envelope.timestamp + 0.375, strength: 1, interval: 1.5))
        for index in 0..<6 {
            envelope.trigger(.init(timestamp: envelope.timestamp + 0.6, strength: 1,
                interval: index < 3 ? 1.5 : 0.6))
        }
        XCTAssertEqual(envelope.releaseDuration, 0.6 * 0.9 - 0.05, accuracy: 0.000_1)
    }

    private func settled(interval: TimeInterval) -> MusicGlowEnvelope {
        var envelope = MusicGlowEnvelope()
        for index in 0..<9 {
            envelope.trigger(.init(timestamp: 10 + Double(index) * interval, strength: 1, interval: interval))
        }
        return envelope
    }

    private func visibility(_ envelope: MusicGlowEnvelope, age: TimeInterval) -> Double {
        MusicGlowAppearance.accentOpacity(envelope.value(at: envelope.timestamp + age))
    }
}

import XCTest
@testable import Nook

final class MusicGlowAppearanceTests: XCTestCase {
    private let base = MusicGlowAppearance.maximumOpacity * MusicGlowAppearance.ambientFraction

    func testAudibleMusicWithoutAccentsFadesIntoStableVisibleBase() {
        var appearance = MusicGlowAppearance()
        XCTAssertEqual(appearance.opacity(at: 0), 0)
        appearance.observeSignal(at: 10)
        XCTAssertEqual(appearance.opacity(at: 10), 0)
        XCTAssertEqual(appearance.opacity(at: 10.15), base * 0.5, accuracy: 0.000_1)
        for time in stride(from: 10.3, through: 15, by: 0.01) {
            appearance.observeSignal(at: time)
            XCTAssertEqual(appearance.opacity(at: time), base, accuracy: 0.000_1)
            XCTAssertEqual(appearance.envelope.value(at: time), 0)
        }
    }

    func testAccentKeepsPeakAndReturnsToBaseInsteadOfDarkness() {
        var appearance = MusicGlowAppearance()
        appearance.observeSignal(at: 9)
        appearance.observeSignal(at: 9.5)
        appearance.observeSignal(at: 10)
        appearance.trigger(.init(timestamp: 10, strength: 1, interval: nil))
        XCTAssertEqual(appearance.opacity(at: 10), base, accuracy: 0.000_1)
        XCTAssertEqual(appearance.opacity(at: 10.05), MusicGlowAppearance.maximumOpacity, accuracy: 0.000_1)
        var previous = MusicGlowAppearance.maximumOpacity
        for time in stride(from: 10.05, through: 11, by: 0.01) {
            appearance.observeSignal(at: time)
            let opacity = appearance.opacity(at: time)
            XCTAssertGreaterThanOrEqual(opacity, base - 0.000_1)
            XCTAssertLessThanOrEqual(opacity, previous + 0.000_1)
            previous = opacity
        }
        XCTAssertEqual(appearance.opacity(at: 11), base, accuracy: 0.000_1)
    }

    func testAccentStrengthStillControlsBrightnessAboveBase() {
        var peaks: [Double] = []
        for strength in [Float(0.35), 0.6, 0.85, 1] {
            var appearance = MusicGlowAppearance()
            appearance.observeSignal(at: 9.5)
            appearance.observeSignal(at: 10)
            appearance.trigger(.init(timestamp: 10, strength: strength, interval: 0.5))
            peaks.append(appearance.opacity(at: 10.05))
        }
        XCTAssertTrue(zip(peaks, peaks.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertTrue(peaks.allSatisfy { $0 > base && $0 <= MusicGlowAppearance.maximumOpacity })
    }

    func testSilenceOrMissingCaptureFadesBaseOutWithoutPeriodicFallback() {
        var appearance = MusicGlowAppearance()
        appearance.observeSignal(at: 9.5)
        appearance.observeSignal(at: 10)
        XCTAssertEqual(appearance.opacity(at: 10.8), base, accuracy: 0.000_1)
        XCTAssertEqual(appearance.opacity(at: 11.05), base * 0.5, accuracy: 0.000_1)
        XCTAssertEqual(appearance.opacity(at: 11.31), 0)
        XCTAssertEqual(appearance.opacity(at: 20), 0)
    }

    func testSignalReturningDuringFadeStartsFromCurrentLevel() {
        var appearance = MusicGlowAppearance()
        appearance.observeSignal(at: 9.5)
        appearance.observeSignal(at: 10)
        let before = appearance.opacity(at: 11.05)
        appearance.observeSignal(at: 11.05)
        XCTAssertEqual(appearance.opacity(at: 11.05), before, accuracy: 0.000_1)
        XCTAssertEqual(appearance.opacity(at: 11.2), (before + base) * 0.5, accuracy: 0.000_1)
        XCTAssertEqual(appearance.opacity(at: 11.35), base, accuracy: 0.000_1)
    }

    func testOutOfOrderAndInvalidSignalTimestampsCannotRestartBase() {
        var appearance = MusicGlowAppearance()
        appearance.observeSignal(at: 10)
        let before = appearance
        for time in [9, 10, .nan, .infinity] {
            appearance.observeSignal(at: time)
            XCTAssertEqual(appearance, before)
        }
        XCTAssertEqual(appearance.opacity(at: .nan), 0)
        XCTAssertEqual(appearance.opacity(at: .infinity), 0)
    }

    func testPauseFadeSamplesVisibleBrightnessAndHasFiniteEnd() {
        for startOpacity in [base, 0.5, MusicGlowAppearance.maximumOpacity] {
            let fade = MusicGlowFadeOut(startTime: 10, startOpacity: startOpacity)
            XCTAssertEqual(fade.opacity(at: 10), startOpacity)
            XCTAssertEqual(fade.opacity(at: 10 + MusicGlowFadeOut.duration / 2), startOpacity * 0.5, accuracy: 0.000_1)
            XCTAssertEqual(fade.opacity(at: 10.46), 0)
            XCTAssertEqual(fade.opacity(at: 20), 0)
        }
    }

    func testAccentOnlyMappingRetainsOriginalVisibilityCurve() {
        XCTAssertEqual(MusicGlowAppearance.accentOpacity(0.12), 0, accuracy: 0.000_1)
        XCTAssertEqual(MusicGlowAppearance.accentOpacity(0.56), 0.475, accuracy: 0.000_1)
        XCTAssertEqual(MusicGlowAppearance.accentOpacity(1), 0.95)
        XCTAssertEqual(MusicGlowAppearance.accentOpacity(.nan), 0)
    }

    func testSlowTailKeepsApprovedPeakAndFloorWhileExtendingVisibleFalloff() {
        var appearance = slowAppearance()
        let time = appearance.envelope.timestamp
        XCTAssertEqual(appearance.opacity(at: time + 0.05), MusicGlowAppearance.maximumOpacity, accuracy: 0.000_1)
        for age in stride(from: 0.1, through: 1.7, by: 0.01) {
            appearance.observeSignal(at: time + age)
        }
        XCTAssertGreaterThan(appearance.opacity(at: time + 0.9), base + 0.1)
        XCTAssertEqual(appearance.opacity(at: time + 1.6), base, accuracy: 0.000_1)
    }

    func testSilenceExpiresEvenLongestAccentAndCannotEmitAnotherFlash() {
        let appearance = slowAppearance()
        let time = appearance.envelope.timestamp
        XCTAssertGreaterThan(appearance.opacity(at: time + 0.9), base)
        // The floor uses its existing 800ms grace + 500ms fade. The last
        // genuine accent may finish its finite tail, but never renews itself.
        XCTAssertGreaterThan(appearance.envelope.value(at: time + 1.31), 0)
        XCTAssertEqual(appearance.opacity(at: time + 1.56), 0)
        XCTAssertEqual(appearance.opacity(at: time + 4), 0)
    }

    func testPauseDuringLongTailUsesExistingFiniteFadeInsteadOfSlowPace() {
        let appearance = slowAppearance()
        let time = appearance.envelope.timestamp + 0.7
        let opacity = appearance.opacity(at: time)
        XCTAssertGreaterThan(opacity, base)
        let fade = MusicGlowFadeOut(startTime: time, startOpacity: opacity)
        XCTAssertEqual(fade.opacity(at: time), opacity)
        XCTAssertEqual(fade.opacity(at: time + 0.46), 0)
    }

    func testSignalResumingDuringLongTailCannotJumpItsBrightness() {
        var appearance = slowAppearance()
        let time = appearance.envelope.timestamp + 1.05
        let opacity = appearance.opacity(at: time)
        let envelope = appearance.envelope
        appearance.observeSignal(at: time)
        XCTAssertEqual(appearance.opacity(at: time), opacity, accuracy: 0.000_1)
        XCTAssertEqual(appearance.envelope, envelope)
    }

    private func slowAppearance() -> MusicGlowAppearance {
        var appearance = MusicGlowAppearance()
        for index in 0..<9 {
            let time = 10 + Double(index) * 2.2
            appearance.observeSignal(at: time - 0.5)
            appearance.observeSignal(at: time)
            appearance.trigger(.init(timestamp: time, strength: 1, interval: 2.2))
        }
        return appearance
    }
}

import XCTest
@testable import Nook

final class MusicGlowPresentationModeTests: XCTestCase {
    func testOuterGlowUsesSimulatedModeWithoutBetaOrAudioAnalysis() {
        XCTAssertEqual(
            resolve(edge: true, beta: false, playing: true, analyzer: false),
            .simulated
        )
        XCTAssertFalse(shouldAnalyze(edge: true, beta: false, playing: true))
    }

    func testReactiveModeBeginsOnlyAfterBetaAnalyzerIsRunning() {
        XCTAssertEqual(
            resolve(edge: true, beta: true, playing: true, analyzer: false),
            .simulated
        )
        XCTAssertTrue(shouldAnalyze(edge: true, beta: true, playing: true))
        XCTAssertEqual(
            resolve(edge: true, beta: true, playing: true, analyzer: true),
            .reactive
        )
    }

    func testDisablingBetaFallsBackToSimulatedWithoutDisablingOuterGlow() {
        XCTAssertEqual(
            resolve(edge: true, beta: false, playing: true, analyzer: true),
            .simulated
        )
    }

    func testOuterGlowAndPlaybackGateBothPresentationAndAnalysis() {
        XCTAssertEqual(
            resolve(edge: false, beta: true, playing: true, analyzer: true),
            .hidden
        )
        XCTAssertFalse(shouldAnalyze(edge: false, beta: true, playing: true))

        XCTAssertEqual(
            resolve(edge: true, beta: true, playing: false, analyzer: true),
            .hidden
        )
        XCTAssertFalse(shouldAnalyze(edge: true, beta: true, playing: false))
    }

    func testCompetingGlowTemporarilyHidesMusicPresentation() {
        XCTAssertEqual(
            MusicGlowPresentationMode.resolve(
                isEdgeGlowEnabled: true,
                isAudioReactiveEnabled: true,
                isPlaying: true,
                isAnalyzerRunning: true,
                canPresentGlow: false
            ),
            .hidden
        )
    }

    private func resolve(
        edge: Bool,
        beta: Bool,
        playing: Bool,
        analyzer: Bool
    ) -> MusicGlowPresentationMode {
        MusicGlowPresentationMode.resolve(
            isEdgeGlowEnabled: edge,
            isAudioReactiveEnabled: beta,
            isPlaying: playing,
            isAnalyzerRunning: analyzer,
            canPresentGlow: true
        )
    }

    private func shouldAnalyze(edge: Bool, beta: Bool, playing: Bool) -> Bool {
        MusicGlowPresentationMode.shouldAnalyzeAudio(
            isEdgeGlowEnabled: edge,
            isAudioReactiveEnabled: beta,
            isPlaying: playing
        )
    }
}

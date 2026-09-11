//
//  MusicGlowPresentationMode.swift
//  Nook
//
//  Pure policy separating the permission-free glow from Beta audio analysis.
//

nonisolated enum MusicGlowPresentationMode: Equatable {
    case hidden
    case simulated
    case reactive

    static func resolve(
        isEdgeGlowEnabled: Bool,
        isAudioReactiveEnabled: Bool,
        isPlaying: Bool,
        isAnalyzerRunning: Bool,
        canPresentGlow: Bool,
        isFadingOut: Bool = false
    ) -> MusicGlowPresentationMode {
        guard isEdgeGlowEnabled, canPresentGlow else {
            return .hidden
        }
        guard isPlaying else {
            return isAudioReactiveEnabled && isFadingOut ? .reactive : .hidden
        }
        guard isAudioReactiveEnabled, isAnalyzerRunning else {
            return .simulated
        }
        return .reactive
    }

    static func shouldAnalyzeAudio(
        isEdgeGlowEnabled: Bool,
        isAudioReactiveEnabled: Bool,
        isPlaying: Bool
    ) -> Bool {
        isEdgeGlowEnabled && isAudioReactiveEnabled && isPlaying
    }
}

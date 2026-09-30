//
//  BetaFeaturesSettingsView.swift
//  Nook
//
//  Explicit opt-ins for experimental features.
//

import AppKit
import Combine
import CoreAudio
import SwiftUI

struct BetaFeaturesSettingsView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color
    let musicBundleIdentifier: String?

    @ObservedObject private var musicAudioAnalyzer = MusicAudioAnalyzer.shared
    @AppStorage(AppSettings.musicAudioReactiveGlowEnabledKey)
    private var musicAudioReactiveGlowEnabled = false
    @State private var didAppear = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 4) {
                MenuRow(
                    icon: "chevron.left",
                    label: "Back",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 0
                ) {
                    viewModel.navigateBack()
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                MenuToggleRow(
                    icon: "waveform",
                    label: "Audio-Reactive Music Glow",
                    isOn: musicAudioReactiveGlowEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 1
                ) {
                    toggleAudioReactiveMusicGlow()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            didAppear = true
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            switch viewModel.settingsFocusedIndex {
            case 0: viewModel.navigateBack()
            case 1: toggleAudioReactiveMusicGlow()
            default: break
            }
        }
    }

    private func toggleAudioReactiveMusicGlow() {
        if musicAudioReactiveGlowEnabled {
            musicAudioReactiveGlowEnabled = false
            musicAudioAnalyzer.stop()
            return
        }

        guard musicAudioAnalyzer.activationState != .requesting else { return }

        // Put the system permission sheet in front instead of leaving it hidden
        // behind Nook's compact settings panel.
        viewModel.notchClose()
        NSApp.activate(ignoringOtherApps: true)
        musicAudioAnalyzer.requestActivation(bundleIdentifier: musicBundleIdentifier) { result in
            switch result {
            case .success:
                musicAudioReactiveGlowEnabled = true
            case .failure(let error):
                musicAudioReactiveGlowEnabled = false
                handleMusicAudioActivationFailure(error)
            }
        }
    }

    private func handleMusicAudioActivationFailure(_ error: Error) {
        NSLog("Audio-Reactive Music Glow could not start system audio capture: %@", error.localizedDescription)
        let nsError = error as NSError
        if nsError.code == Int(kAudioDevicePermissionsError),
           let url = URL(
               string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
           ) {
            NSWorkspace.shared.open(url)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Audio-Reactive Music Glow Couldn’t Start"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

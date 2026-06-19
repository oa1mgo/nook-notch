//
//  SoundPickerRow.swift
//  Nook
//
//  Notification sound selection picker for settings menu
//

import SwiftUI

struct SoundPickerRow: View {
    @ObservedObject var soundSelector: SoundSelector
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    @State private var selectedSound: NotificationSound = AppSettings.notificationSound

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: { soundSelector.isPickerExpanded },
            set: { soundSelector.isPickerExpanded = $0 }
        )
    }

    var body: some View {
        ExpandableSettingsRow(
            icon: "speaker.wave.2",
            label: "Notification Sound",
            trailingText: selectedSound.rawValue,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            isFocused: isFocused,
            isExpanded: isExpandedBinding
        ) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(NotificationSound.allCases, id: \.self) { sound in
                        SettingsSubPickerRow(
                            label: sound.rawValue,
                            isSelected: selectedSound == sound,
                            primaryTextColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor
                        ) {
                            NotificationSoundPlayer.play(sound)
                            selectedSound = sound
                            AppSettings.notificationSound = sound
                        }
                    }
                }
            }
            .frame(maxHeight: CGFloat(min(NotificationSound.allCases.count, 6)) * 32)
        }
        .onAppear {
            selectedSound = AppSettings.notificationSound
        }
    }
}

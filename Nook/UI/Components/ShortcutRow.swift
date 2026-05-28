//
//  ShortcutRow.swift
//  Nook
//
//  A single action row in the shortcuts settings page with recording support
//

import SwiftUI
import Combine

struct ShortcutRow: View {
    let action: ShortcutAction
    let primaryTextColor: Color
    let secondaryTextColor: Color
    @ObservedObject var store: ShortcutStore
    @Binding var recordingAction: ShortcutAction?
    var onConflict: ((ShortcutAction) -> Void)?
    var isFocused: Bool = false

    @State private var isHovered = false

    private var combinations: [KeyCombination] {
        store.combinations(for: action)
    }

    private var isRecording: Bool {
        recordingAction == action
    }

    var body: some View {
        Button {
            if recordingAction == nil {
                recordingAction = action
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.sfSymbolName)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(action.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                if isRecording {
                    Text("Press shortcut...")
                        .font(.system(size: 11))
                        .foregroundColor(TerminalColors.green)
                        .transition(.opacity)
                } else if combinations.isEmpty {
                    Text("None")
                        .font(.system(size: 11))
                        .foregroundColor(secondaryTextColor)
                } else {
                    HStack(spacing: 4) {
                        ForEach(Array(combinations.enumerated()), id: \.offset) { _, combo in
                            KeyCombinationView(
                                combination: combo,
                                onRemove: { removeCombo(combo) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(focusBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isRecording ? TerminalColors.green.opacity(0.5) : (isFocused ? Color.white.opacity(0.25) : Color.clear), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var focusBackgroundColor: Color {
        if isRecording {
            return Color.white.opacity(0.12)
        }
        if isFocused {
            return Color.white.opacity(0.12)
        }
        return isHovered ? Color.white.opacity(0.08) : Color.clear
    }

    private var textColor: Color {
        primaryTextColor.opacity(isHovered || isRecording ? 1.0 : 0.82)
    }

    private func removeCombo(_ combo: KeyCombination) {
        store.removeCombination(combo, from: action)
    }
}

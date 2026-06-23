//
//  ShortcutSettingsView.swift
//  Nook
//
//  Settings page for configuring keyboard shortcuts
//

import SwiftUI
import Combine

struct ShortcutSettingsView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color
    @ObservedObject private var store = ShortcutStore.shared
    @State private var recordingAction: ShortcutAction?
    @State private var showResetConfirm = false
    @State private var conflictFlash: ShortcutAction?

    /// Actions the user can rebind in Settings. Excludes `.scrollToBottom`
    /// — it's still in `ShortcutAction` (so `NotchViewModel.handleShortcutAction`
    /// can dispatch it) but the user has no use for it as a customizable
    /// shortcut here, so we hide the row.
    private var visibleActions: [ShortcutAction] {
        ShortcutAction.allCases.filter { $0 != .scrollToBottom }
    }
    @State private var isResetHovered = false
    @State private var didAppear = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 4) {
                // Back button
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

                // Action rows
                ForEach(Array(visibleActions.enumerated()), id: \.element) { offset, action in
                    ShortcutRow(
                        action: action,
                        primaryTextColor: primaryTextColor,
                        secondaryTextColor: secondaryTextColor,
                        store: store,
                        recordingAction: $recordingAction,
                        onConflict: { conflicting in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                conflictFlash = conflicting
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                withAnimation { conflictFlash = nil }
                            }
                        },
                        isFocused: viewModel.settingsFocusedIndex == offset + 1
                    )
                    .overlay(
                        conflictFlash == action
                            ? RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red.opacity(0.6), lineWidth: 1)
                            : nil
                    )
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // Reset row
                Group {
                    if showResetConfirm {
                        let isFocus = viewModel.settingsFocusedIndex == 8
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 12))
                                .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                                .frame(width: 16)

                            Text("Reset all shortcuts?")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))

                            Spacer()

                            Button {
                                showResetConfirm = false
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(primaryTextColor.opacity(0.7))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(primaryTextColor.opacity(0.2), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)

                            Button {
                                store.resetToDefaults()
                                showResetConfirm = false
                            } label: {
                                Text("Reset")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Color(red: 1.0, green: 0.4, blue: 0.4))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isFocus ? Color.white.opacity(0.12) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isFocus ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1)
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        let isFocus = viewModel.settingsFocusedIndex == 8
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showResetConfirm = true
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 12))
                                    .foregroundColor(textColor)
                                    .frame(width: 16)

                                Text("Restore Defaults")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(textColor)

                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isFocus ? Color.white.opacity(0.12) : (isResetHovered ? Color.white.opacity(0.08) : Color.clear))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isFocus ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .onHover { isResetHovered = $0 }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: showResetConfirm)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: recordingAction) { _, newValue in
            ShortcutManager.shared.isRecording = (newValue != nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutKeyDown)) { notification in
            handleKeyDown(notification)
        }
        .onAppear {
            didAppear = true
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            let i = viewModel.settingsFocusedIndex
            if i == 0 {
                viewModel.navigateBack()
            } else if i >= 1 && i <= 7 {
                let actions = visibleActions
                let idx = i - 1
                guard idx < actions.count else { return }
                if recordingAction == nil {
                    recordingAction = actions[idx]
                }
            } else if i == 8 {
                if showResetConfirm {
                    store.resetToDefaults()
                    showResetConfirm = false
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showResetConfirm = true
                    }
                }
            }
        }
    }

    private var textColor: Color {
        primaryTextColor.opacity(isResetHovered ? 1.0 : 0.82)
    }

    private func handleKeyDown(_ notification: Notification) {
        guard let event = notification.object as? NSEvent,
              let recording = recordingAction else { return }

        let combo = KeyCombination.from(event: event)

        // Esc during recording — cancel
        if combo.keyCode == 53 {
            recordingAction = nil
            return
        }

        // Backspace — remove last combination
        if combo.keyCode == 51 {
            store.removeLastCombination(from: recording)
            recordingAction = nil
            return
        }

        // Add combination
        let success = store.addCombination(combo, to: recording)
        if success {
            recordingAction = nil
        } else {
            // Conflict — flash and stay in recording mode
            if let conflict = store.findConflict(combo) {
                conflictFlash = conflict
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation { conflictFlash = nil }
                }
            }
        }
    }
}

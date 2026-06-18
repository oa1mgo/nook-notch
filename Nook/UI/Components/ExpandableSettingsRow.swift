//
//  ExpandableSettingsRow.swift
//  Nook
//
//  Reusable expandable/collapsible settings row with sub-items.
//  Mirrors the SoundPickerRow pattern: hover + full-row click on both
//  the header and sub-rows.
//

import SwiftUI

struct ExpandableSettingsRow<Content: View>: View {
    let icon: String
    let label: String
    var trailingText: String? = nil
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    @Binding var isExpanded: Bool

    @State private var isHovered = false

    @ViewBuilder private var content: () -> Content

    init(
        icon: String,
        label: String,
        trailingText: String? = nil,
        primaryTextColor: Color = .white,
        secondaryTextColor: Color = .white.opacity(0.4),
        isFocused: Bool = false,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.label = label
        self.trailingText = trailingText
        self.primaryTextColor = primaryTextColor
        self.secondaryTextColor = secondaryTextColor
        self.isFocused = isFocused
        self._isExpanded = isExpanded
        self.content = content
    }

    private var textColor: Color {
        primaryTextColor.opacity(isHovered ? 1.0 : 0.82)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    if let trailingText {
                        Text(trailingText)
                            .font(.system(size: 11))
                            .foregroundColor(secondaryTextColor)
                            .lineLimit(1)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(secondaryTextColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isFocused ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.08) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                VStack(spacing: 2) {
                    content()
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Sub Picker Row (二级选项条目，用于 SoundPicker / ScreenPicker / ClaudeDirPicker)

struct SettingsSubPickerRow: View {
    let label: String
    var sublabel: String? = nil
    var sublabelDesign: Font.Design = .default
    /// When true, sublabel is stacked below label (VStack); otherwise inline (HStack).
    var verticalSublabel: Bool = false
    let isSelected: Bool
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                if verticalSublabel {
                    VStack(alignment: .leading, spacing: 1) {
                        labelView
                        if let sublabel { sublabelView }
                    }
                } else {
                    labelView
                    if let sublabel { sublabelView }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var labelView: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(primaryTextColor.opacity(isHovered ? 1.0 : 0.82))
    }

    private var sublabelView: some View {
        Text(sublabel!)
            .font(.system(size: 10, design: sublabelDesign))
            .foregroundColor(secondaryTextColor)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

// MARK: - Sub Toggle Row (二级 toggle 条目)

struct SettingsSubToggleRow: View {
    let label: String
    let isOn: Bool
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    var locked: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(primaryTextColor.opacity(isHovered ? 1.0 : 0.82))

                Spacer()

                Circle()
                    .fill(isOn ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isFocused ? Color.white.opacity(0.08) : (isHovered ? Color.white.opacity(0.06) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .opacity(locked ? 0.5 : 1.0)
    }
}

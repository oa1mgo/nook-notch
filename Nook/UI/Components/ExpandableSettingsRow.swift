//
//  ExpandableSettingsRow.swift
//  Nook
//
//  Reusable expandable/collapsible settings row with sub-items.
//  Mirrors the SoundPickerRow pattern: hover + full-row click on both
//  the header and sub-rows.
//

import SwiftUI

struct ExpandableSettingsRow<Content: View, Icon: View>: View {
    let icon: String
    /// Optional override for the leading icon (brand logo etc.). When
    /// provided, replaces the SF Symbol `icon`. Generic over `Icon` so
    /// the brand logo's concrete type is preserved — no `AnyView`
    /// allocation. See `MenuRow<Icon>` for the same trade-off.
    var customIcon: Icon? = nil
    let label: String
    var trailingText: String? = nil
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    @Binding var isExpanded: Bool

    /// Called inside the `withAnimation(.settingsExpand)` block when the
    /// user taps the row header. Receives the NEW `isExpanded` value and
    /// the measured content height — so the parent can update the panel's
    /// `menuContentHeight` (or equivalent) synchronously, in the same
    /// animation transaction as `isExpanded.toggle()`. This eliminates
    /// the 1-2 frame lag between picker animation and panel animation
    /// that causes scrollbar flicker.
    ///
    /// The measured height is 0 on the first expand (before the
    /// GeometryReader has reported), but `ExpandableContent.hasMeasured`
    /// suppresses animation in that window, so the snap is harmless.
    var onToggle: ((Bool, CGFloat) -> Void)? = nil

    /// Height the picker occupies when expanded. Provided by the
    /// parent via `PickerLayout.expandedHeight` — see
    /// `SettingsPageLayout.swift`. No measurement feedback.
    let targetHeight: CGFloat

    @State private var isHovered = false

    @ViewBuilder private var content: () -> Content

    init(
        icon: String,
        customIcon: Icon? = nil,
        label: String,
        trailingText: String? = nil,
        primaryTextColor: Color = .white,
        secondaryTextColor: Color = .white.opacity(0.4),
        isFocused: Bool = false,
        isExpanded: Binding<Bool>,
        targetHeight: CGFloat,
        onToggle: ((Bool, CGFloat) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.customIcon = customIcon
        self.label = label
        self.trailingText = trailingText
        self.primaryTextColor = primaryTextColor
        self.secondaryTextColor = secondaryTextColor
        self.isFocused = isFocused
        self._isExpanded = isExpanded
        self.targetHeight = targetHeight
        self.onToggle = onToggle
        self.content = content
    }

    private var textColor: Color {
        primaryTextColor.opacity(isHovered ? 1.0 : 0.82)
    }

    @ViewBuilder
    private var iconView: some View {
        if let customIcon {
            customIcon.frame(width: 16)
        } else {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                let newExpanded = !isExpanded
                // Report the toggle INSIDE the same `withAnimation` so the
                // panel height animates alongside the picker's frame. Both
                // share the same `.easeInOut(duration: 0.2)` curve, so the
                // OUTER ScrollView's contentView tracks the VStack's
                // contentSize throughout the transition. Panel height and
                // VStack contentSize are driven by the same
                // `PickerLayout.expandedHeight`, so they reach the same
                // value at the same frame — no scrollbar flash.
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = newExpanded
                    onToggle?(newExpanded, targetHeight)
                }
            } label: {
                HStack(spacing: 10) {
                    iconView

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
            .buttonStyle(NoPressButtonStyle())
            .onHover { isHovered = $0 }

            // Render the same content tree always so the natural height is
            // available regardless of collapsed state. ExpandableContent
            // clamps the visible height to 0 (via .frame + .clipped) when
            // isExpanded is false; the picker's target height is provided
            // by the parent (PickerLayout.expandedHeight) — no measurement
            // feedback.
            ExpandableContent(
                isExpanded: isExpanded,
                targetHeight: targetHeight
            ) {
                VStack(spacing: 2) {
                    content()
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Sub Picker Row (二级 picker 条目)

struct SettingsSubPickerRow: View {
    let label: String
    var sublabel: String? = nil
    var sublabelDesign: Font.Design = .default
    /// When true, sublabel is stacked below label (VStack); otherwise inline (HStack).
    var verticalSublabel: Bool = false
    let isSelected: Bool
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    /// Effective stacked-sublabel layout. When the caller asks for a
    /// vertical sublabel but `sublabel` is nil, we fall back to the
    /// small inline layout — otherwise the row would render the title
    /// at the top of an otherwise-empty stacked slot, leaving 13pt of
    /// dead space below the title (visible "title floats up" effect).
    ///
    /// The picker's `PickerLayout` must pick the matching row height
    /// (see SettingsPageLayout.swift / each picker integration) so the
    /// picker's contentSize and the panel height stay in lock-step.
    private var showsVerticalSublabel: Bool {
        verticalSublabel && sublabel != nil
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                if showsVerticalSublabel {
                    // VStack(alignment: .leading, spacing: 1) so the
                    // sublabel sits flush under the label. Title fits on
                    // top, sublabel below — same composition as
                    // MenuRow.trailingLabel stacked above its parent
                    // row.
                    VStack(alignment: .leading, spacing: 1) {
                        labelView
                        sublabelView
                    }
                } else {
                    labelView
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
                    .fill(isFocused ? Color.white.opacity(0.10) : (isHovered ? Color.white.opacity(0.06) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Color.white.opacity(0.22) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(NoPressButtonStyle())
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
        .buttonStyle(NoPressButtonStyle())
        .onHover { isHovered = $0 }
        .opacity(locked ? 0.5 : 1.0)
    }
}

/// Convenience init for the common case (no `customIcon`). Pins
/// `Icon` to `EmptyView` so existing call sites don't need to
/// specify the generic parameter.
extension ExpandableSettingsRow where Icon == EmptyView {
    init(
        icon: String,
        label: String,
        trailingText: String? = nil,
        primaryTextColor: Color = .white,
        secondaryTextColor: Color = .white.opacity(0.4),
        isFocused: Bool = false,
        isExpanded: Binding<Bool>,
        targetHeight: CGFloat,
        onToggle: ((Bool, CGFloat) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            icon: icon,
            customIcon: nil as Icon?,
            label: label,
            trailingText: trailingText,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            isFocused: isFocused,
            isExpanded: isExpanded,
            targetHeight: targetHeight,
            onToggle: onToggle,
            content: content
        )
    }
}

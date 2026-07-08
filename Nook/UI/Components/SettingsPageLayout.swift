//
//  SettingsPageLayout.swift
//  Nook
//
//  Compile-time layout arithmetic for the settings pages (menu, agents,
//  performance settings). Replaces the old GeometryReader feedback loop
//  (GeometryReader → onPreferenceChange → viewModel.contentHeight →
//  openedSize → panel.maxHeight) that was responsible for the 9-fix
//  scrollbar flicker saga — see PROGRESS.md "Scrollbar flicker 9 次修复
//  经验". With deterministic layout, panel height and ScrollView
//  contentSize are mathematically equal at every frame, so the scrollbar
//  never flashes.
//
//  Sources of truth here:
//  - `rowHeight` is derived from `NSFont.systemFont(ofSize:weight:)`
//    metrics (ascender − descender + leading) plus the SwiftUI
//    `.padding(.vertical,)` modifier. The font's typographic line
//    height is bit-for-bit identical to what SwiftUI's Text uses
//    internally when rendering the same font, so the height we report
//    matches SwiftUI's actual row allocation (no subpixel error).
//  - VStack `spacing: 4` is uniform across all three pages.
//  - `headerHeight` mirrors `max(24, deviceNotchRect.height)`.
//

import SwiftUI
import AppKit

// MARK: - Font-metric helpers

/// Line height of `NSFont.systemFont(ofSize: size, weight: weight)` —
/// equal to `ascender - descender + leading`. The font's typographic
/// line height, byte-for-byte.
@inline(__always)
func fontLineHeight(size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    let f = NSFont.systemFont(ofSize: size, weight: weight)
    return f.ascender - f.descender + f.leading
}

/// SwiftUI's Text natural rendering height for a system font of the
/// given size and weight.
///
/// SwiftUI does NOT use `fontLineHeight` (= asc - desc + leading)
/// directly — it rounds the typographic line height to the nearest
/// integer and adds 1pt of descender safety margin to compute the
/// text view's intrinsic content size. Verified by GeometryReader
/// measurements against the actual rendered row heights in
/// `SettingsSubPickerRow`:
///
///     12pt medium  → round(14.13) + 1 = 15pt
///     10pt regular → round(11.78) + 1 = 13pt
///
/// Without this adjustment, every picker row in the settings panel
/// was underestimated by ~0.87pt, accumulating to a visible
/// "clipped last row" effect (5+pt short at the bottom of an
/// expanded 6-row picker like SoundPicker).
///
/// For fixed-height children (e.g. `.frame(width: 16)` on an SF
/// Symbol), SwiftUI uses the exact value — no rounding. So
/// `menuRowHeightDefault` (icon-driven) keeps using `fontLineHeight`.
@inline(__always)
func textRenderHeight(size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    CGFloat(Int(fontLineHeight(size: size, weight: weight).rounded())) + 1
}

// MARK: - Row height constants (font-metric-derived)
//
// These are computed once at module load and frozen as constants. They
// mirror the SwiftUI modifiers in each row type:
//
//   MenuRow                : 13pt medium label, 12pt SF Symbol icon
//                            in .frame(width: 16), .padding(.vertical, 10)
//                            HStack height = max(12, fontLineHeight(13, .medium))
//                            Button height = HStack + 20
//                            → 35.310546875pt
//
//   MenuToggleRow          : 13pt medium label + 11pt on/off, vpadding 10
//                            HStack = max(Text 13pt, Circle 6, Text 11pt)
//                            Button = HStack + 20
//                            → 35.310546875pt
//
//   SettingsSubToggleRow   : 12pt medium label + 11pt on/off, vpadding 6
//                            HStack = max(Text 12pt, Circle 6, Text 11pt)
//                            Button = HStack + 12
//                            → 26.1328125pt
//
//   SettingsSubPickerRow
//   (no sublabel)          : 12pt label, .padding(.vertical, 6)
//                            HStack = max(Text 12pt, Circle 6)
//                            Button = HStack + 12
//                            → 26.1328125pt
//
//   SettingsSubPickerRow
//   (verticalSublabel)     : 12pt label + spacing 1 + 10pt sublabel
//                            HStack = max(Circle 6, fontLineHeight(12,.medium)
//                                         + 1 + fontLineHeight(10,.regular))
//                            Button = HStack + 12
//                            → 38.91015625pt

/// MenuRow / MenuToggleRow / ExpandableSettingsRow header (13pt label,
/// 10/10 vertical padding, icon .frame(width: 16)).
///
/// Theoretical default: max(font line-height, SF Symbol height) + padding.
/// SwiftUI's HStack height is driven by the tallest child — the 16pt-wide
/// SF Symbol can be taller than the 13pt text line-box, so we take the max.
let menuRowHeightDefault: CGFloat = max(
    fontLineHeight(size: 13, weight: .medium),
    16.0 // SF Symbol intrinsic height when .frame(width: 16) is applied
) + 20

/// Runtime-corrected row height. Measured from the first rendered MenuRow.
/// Falls back to `menuRowHeightDefault` before the first measurement.
var menuRowHeight: CGFloat = menuRowHeightDefault

/// SettingsSubToggleRow (12pt label, 6/6 vertical padding = 12pt total).
let settingsSubToggleRowHeight: CGFloat = textRenderHeight(size: 12, weight: .medium) + 12

/// SettingsSubPickerRow without a sublabel (12pt label, 6/6 vertical
/// padding = 12pt total).
///
/// Two adjustments vs. raw `fontLineHeight`:
///
/// 1. `.padding(.vertical, 10)` was once written here (20pt padding),
///    then reduced to `.padding(.vertical, 6)` (12pt) for a more
///    compact look. The formula was updated from +20 to +12.
/// 2. SwiftUI's Text natural height is `round(lineHeight) + 1`, not
///    `lineHeight` itself (see `textRenderHeight`). Without that, each
///    row was underestimated by 0.87pt → last row's hover rectangle
///    was clipped at the bottom of expanded pickers.
let settingsSubPickerRowHeight: CGFloat = textRenderHeight(size: 12, weight: .medium) + 12

/// SettingsSubPickerRow with `verticalSublabel: true` (12pt label +
/// 1pt spacing + 10pt sublabel stacked, plus 6/6 vpadding = 12pt total).
///
/// Both the label and sublabel use `textRenderHeight` so the formula
/// matches SwiftUI's actual rendering for both Text elements and the
/// `Color.clear` placeholder that reserves the sublabel slot when
/// `sublabel == nil`.
let settingsSubPickerRowVerticalSublabelHeight: CGFloat =
    textRenderHeight(size: 12, weight: .medium)
    + 1
    + textRenderHeight(size: 10, weight: .regular)
    + 12

// MARK: - Picker layout

/// Compile-time layout for a single picker's expanded content.
///
/// The picker renders `N` `SettingsSubPickerRow`s inside a VStack with
/// `rowSpacing`, prefixed by a 4pt top padding (set by
/// `ExpandableSettingsRow`). Each row has its own height; the total
/// visible height when expanded is therefore:
///
///     sum(rowHeights) + (N - 1) * rowSpacing + 4
///
/// All numbers are known at init time, so the picker reports its
/// expanded height synchronously without measuring.
///
/// Row heights should be one of the font-metric-derived constants above
/// (`settingsSubToggleRowHeight` / `settingsSubPickerRowHeight` /
/// `settingsSubPickerRowVerticalSublabelHeight`) so the reported
/// height matches SwiftUI's actual layout to within subpixel.
///
/// Rows can be MIXED heights — `SettingsSubPickerRow` falls back to the
/// small inline layout (`settingsSubPickerRowHeight`) when its
/// caller's sublabel is nil at runtime, even though the caller passed
/// `verticalSublabel: true`. ScreenPickerRow and AgentSettingsView
/// exercise this path; pickers with always-non-nil sublabels can use
/// the homogeneous `init(rowCount:rowHeight:)` overload.
struct PickerLayout: Equatable {
    /// Per-row height. One entry per `SettingsSubPickerRow` in the
    /// picker's VStack, in render order.
    let rowHeights: [CGFloat]
    /// VStack spacing inside the picker content. Matches the
    /// `VStack(spacing: 2)` in `ExpandableSettingsRow`.
    let rowSpacing: CGFloat
    /// Outer `.padding(.top, 4)` set by `ExpandableSettingsRow`.
    let topPadding: CGFloat

    /// Per-row layout — use when rows can have different heights (a
    /// row's sublabel presence is data-dependent).
    init(
        rowHeights: [CGFloat],
        rowSpacing: CGFloat = 2,
        topPadding: CGFloat = 4
    ) {
        self.rowHeights = rowHeights
        self.rowSpacing = rowSpacing
        self.topPadding = topPadding
    }

    /// Homogeneous-row convenience init. Use this when every row in the
    /// picker has the same height — e.g. `SettingsSubToggleRow` rows
    /// (PerformanceSettingsView), `SettingsSubPickerRow` rows without
    /// sublabels (SoundPickerRow), or rows whose caller always passes a
    /// non-nil sublabel (AppearanceStylePickerRow).
    init(
        rowCount: Int,
        rowHeight: CGFloat = settingsSubPickerRowHeight,
        rowSpacing: CGFloat = 2,
        topPadding: CGFloat = 4
    ) {
        self.rowHeights = Array(repeating: rowHeight, count: max(rowCount, 0))
        self.rowSpacing = rowSpacing
        self.topPadding = topPadding
    }

    /// Number of rows in the picker. Derived from `rowHeights` so both
    /// inits agree on the count.
    var rowCount: Int { rowHeights.count }

    /// Height the picker should occupy when expanded. Returns 0 when
    /// collapsed — the picker's frame collapses to 0 instantly in the
    /// legacy animation path, or holds the previous value through the
    /// opacity-fade window in the instant-frame path.
    var expandedHeight: CGFloat {
        guard !rowHeights.isEmpty else { return 0 }
        return rowHeights.reduce(0, +)
            + CGFloat(max(0, rowHeights.count - 1)) * rowSpacing
            + topPadding
    }
}

// MARK: - Page layout

/// Compile-time layout for an entire settings page (e.g. the main menu
/// or the agents page). The VStack inside the page has uniform
/// `spacing: 4`, alternating `MenuRow`-style rows and `Divider`s
/// wrapped in `.padding(.vertical, 4)` (9pt each), inside a container
/// with `.padding(.vertical, 8)` (16pt total).
///
/// The arithmetic in `staticHeight` is intentionally trivial so it can
/// be hand-checked against the VStack's actual rendered size.
struct PageLayout: Equatable {
    let rowCount: Int
    let dividerCount: Int
    /// Per-row height. Defaults to `menuRowHeight` (35.31pt) for
    /// `MenuRow` / `MenuToggleRow` / `ExpandableSettingsRow` header.
    let rowHeight: CGFloat
    /// VStack `spacing: 4` between every element (row or divider).
    let rowSpacing: CGFloat
    /// `Divider().padding(.vertical, 4)` → 4 + 1 + 4 = 9pt visible.
    let dividerHeight: CGFloat
    /// Outer VStack `.padding(.vertical, 8)` → 16pt total.
    let containerVerticalPadding: CGFloat

    init(
        rowCount: Int,
        dividerCount: Int,
        rowHeight: CGFloat = menuRowHeight,
        rowSpacing: CGFloat = 4,
        dividerHeight: CGFloat = 9,
        containerVerticalPadding: CGFloat = 16
    ) {
        self.rowCount = rowCount
        self.dividerCount = dividerCount
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.dividerHeight = dividerHeight
        self.containerVerticalPadding = containerVerticalPadding
    }

    /// Height of the VStack when no picker is expanded. Equal to the
    /// ScrollView's `contentSize` at that state.
    ///
    /// The arithmetic matches SwiftUI's actual layout to within
    /// subpixel, so panel height and ScrollView contentSize are
    /// mathematically equal — no buffer needed, no scrollbar flicker.
    var staticHeight: CGFloat {
        let spacingCount = max(0, rowCount + dividerCount - 1)
        return CGFloat(rowCount) * rowHeight
            + CGFloat(dividerCount) * dividerHeight
            + CGFloat(spacingCount) * rowSpacing
            + containerVerticalPadding
    }

    /// Height of the VStack including the currently-expanded pickers.
    /// `expandedPickerHeights` should contain one entry per picker that
    /// is currently open; collapsed pickers contribute 0.
    func dynamicHeight(expandedPickerHeights: [CGFloat]) -> CGFloat {
        staticHeight + expandedPickerHeights.reduce(0, +)
    }
}

// MARK: - Page header

/// Height of the panel's header row that sits above the VStack.
///
/// **SINGLE SOURCE OF TRUTH** — must be used by every panel-height
/// formula (`.menu` / `.agents` / `.performanceSettings` / `.performance`)
/// and by `NotchView.headerRow.frame(height:)` (see `NotchView.swift`
/// line ~651 — `closedNotchSize.height` is `viewModel.deviceNotchRect.height`).
///
/// History (2026-07-06 fix `55219a2`): this was previously a hardcoded
/// `let settingsPageHeaderHeight: CGFloat = 24`. On devices whose notch
/// is 25pt (or any non-24pt height), the panel was 1pt shorter than the
/// header SwiftUI actually allocated, leaving the ScrollView 1pt short
/// of its content → permanent 1pt overflow → persistent scrollbar.
///
/// Replacing the constant with this function guarantees the formula
/// tracks `NotchView`'s actual allocation at every device. Future
/// developers adding a new panel contentType: call this, do NOT
/// inline `max(24, geometry.deviceNotchRect.height)` again.
func settingsPageHeaderHeight(for geometry: NotchGeometry) -> CGFloat {
    max(24, geometry.deviceNotchRect.height)
}

// MARK: - Panel height formula

/// Compute the panel height for a settings page. This is the single
/// source of truth used by `NotchViewModel.openedSize` for the
/// `.menu` / `.agents` / `.performanceSettings` cases. With this
/// formula the ScrollView's `contentSize` (== `pageLayout.dynamicHeight`)
/// and the panel's `maxHeight` (== `panelHeightForPage`) are
/// **mathematically equal** at every frame, so the scrollbar never
/// flashes.
func panelHeightForPage(
    pageLayout: PageLayout,
    expandedPickerHeights: [CGFloat],
    geometry: NotchGeometry
) -> CGFloat {
    pageLayout.dynamicHeight(expandedPickerHeights: expandedPickerHeights)
        + settingsPageHeaderHeight(for: geometry)
        // Trailing gap between VStack bottom and panel inner padding.
        // Matches the `+ 12` previously baked into the GeometryReader
        // formula in `NotchViewModel.openedSize`.
        + 12
}
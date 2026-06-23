//
//  ExpandableContent.swift
//  Nook
//
//  Animated expand/collapse container. Replaces `if isExpanded { content }`
//  patterns. The content is always in the view tree, but its visible height
//  is clamped via `.frame(height:)`. Toggling `isExpanded` animates the frame
//  with `Animation.settingsExpand` — the same curve used by the panel's
//  `notchSize` animation in `NotchView` — so the content and the panel grow
//  at the same rate and the scrollbar never flashes.
//

import SwiftUI

private struct ExpandableContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ExpandableContent<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder let content: Content

    /// Natural height of `content`, measured by the background GeometryReader.
    /// `0` until the first layout pass reports it.
    @State private var contentHeight: CGFloat = 0

    /// Becomes `true` after the first preference update. The first toggle that
    /// happens before the layout pass completes (e.g. user presses Enter the
    /// instant the page appears) animates from `height: 0` to `height: 0` —
    /// i.e. snaps. We suppress the animation in that window so the snap is
    /// immediate rather than a "0 → 0 → snap to measured height" flicker.
    /// All subsequent toggles animate smoothly.
    @State private var hasMeasured: Bool = false

    var body: some View {
        // `.fixedSize(horizontal: false, vertical: true)` is required for
        // the GeometryReader below to measure the content's TRUE natural
        // height while collapsed. Without it, when `isExpanded` is false
        // the outer `.frame(height: 0)` proposes height 0 to `content`,
        // which a `ScrollView` (or any view that accepts parent proposals)
        // will dutifully report back as 0 — so `contentHeight` stays 0 and
        // the expand animation goes from 0 → 0 (content invisible).
        //
        // `.fixedSize` makes `content` ignore the parent proposal and
        // report its ideal height, so the GeometryReader captures the real
        // value (e.g. 160 for SoundPickerRow) regardless of collapsed
        // state. This is SwiftUI's standard mechanism for "use my ideal
        // size, not what my parent asked for" — not a workaround.
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: ExpandableContentHeightKey.self,
                        value: g.size.height
                    )
                }
            )
            .frame(height: isExpanded ? contentHeight : 0, alignment: .top)
            .clipped()
            .onPreferenceChange(ExpandableContentHeightKey.self) { height in
                contentHeight = height
                if !hasMeasured { hasMeasured = true }
            }
            .animation(
                hasMeasured ? .settingsExpand : nil,
                value: isExpanded
            )
    }
}

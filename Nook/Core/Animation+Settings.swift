//
//  Animation+Settings.swift
//  Nook
//
//  Shared animation constants for settings-related UI.
//

import SwiftUI

extension Animation {
    /// Shared curve + duration for settings expand/collapse transitions.
    ///
    /// Used by:
    /// - `ExpandableContent` — animates picker content frame from 0 → natural height.
    /// - `NotchView` — animates the panel's `notchSize` so the panel keeps up
    ///   with picker growth.
    ///
    /// **Keep these in sync.** If picker growth and panel growth use different
    /// curves or durations, the scrollbar flashes during the mismatch window.
    static let settingsExpand = Animation.easeInOut(duration: 0.2)
}

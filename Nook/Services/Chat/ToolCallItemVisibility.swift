//
//  ToolCallItemVisibility.swift
//  Nook
//
//  View-agnostic visibility predicates for ToolCallItem. Centralising
//  them here lets the SwiftUI layer (ChatView) and tests agree on the
//  same rules instead of duplicating the condition inline.
//

import Foundation

extension ToolCallItem {
    /// Whether the SubagentToolsList should currently be rendered for
    /// this item, given the user's `isExpanded` toggle.
    ///
    /// Visibility is a pure function of `isExpanded`: an expanded
    /// subagent container with at least one recorded sub-tool shows
    /// its tools list; a collapsed one does not. We deliberately do
    /// **not** force-show the list while `status == .running` — the
    /// previous implementation did, which made the row appear
    /// "stuck" expanded: the user could tap the header to toggle
    /// `isExpanded` during running, but the list stayed visible
    /// regardless, so the fold action had no visible effect. After
    /// the change, toggling produces a clean on/off at any status.
    /// The pulsing status dot remains the affordance for "still
    /// running"; the tools-list visibility is fully user-controlled.
    func showsSubagentToolsList(isExpanded: Bool) -> Bool {
        isSubagentContainer && !subagentTools.isEmpty && isExpanded
    }
}

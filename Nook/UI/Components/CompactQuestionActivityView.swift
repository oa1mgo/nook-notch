// CompactQuestionActivityView.swift
// Nook
//
// Closed-notch chip shown when a session is waiting to answer an
// AskUserQuestion. Layout mirrors the permission close-state (provider
// activity carousel): left amber ? pill (semantic "question pending"),
// middle provider+summary, right a provider-tinted * spinner that reads as
// an active waiting state — the same symbol/animation the permission and
// processing header uses (ProcessingSpinner), so the chip stays visually
// consistent with those two waiting-for-input treatments.
//
// The middle text is drawn unconditionally — on devices with a physical
// notch the OS covers it, which is the intended look.

import SwiftUI

struct CompactQuestionActivityView: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    let onTap: () -> Void

    private var primarySession: SessionState? {
        sessionMonitor.instances
            .filter { $0.phase == .waitingForInput && $0.pendingQuestionContext != nil }
            .sorted { $0.lastActivity > $1.lastActivity }
            .first
    }

    private var summaryText: String {
        primarySession?.pendingQuestionContext?.questions.first?.question ?? "Question pending"
    }

    private var providerLabel: String {
        (primarySession?.provider.rawValue ?? "").uppercased()
    }

    var body: some View {
        HStack(spacing: 8) {
            // Left: same pixel-art icon as the permission close-state,
            // tinted amber so it reads as the question sibling.
            PermissionIndicatorIcon(size: 16, color: TerminalColors.amber)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 0) {
                Text("\(providerLabel) · QUESTION")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(summaryText)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            // Right: provider-tinted * spinner — mirrors the permission /
            // processing header so the closed chip reads as an active
            // waiting state rather than a static label. Falls back to the
            // Claude tint when no waiting session resolves (e.g. race on
            // dismissal).
            ProcessingSpinner(provider: primarySession?.provider ?? .claude)
                .frame(width: 16, height: 16)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// CompactQuestionActivityView.swift
// Nook
//
// Closed-notch chip shown when a session is waiting to answer an
// AskUserQuestion. Layout mirrors the agent close-state (provider activity
// carousel): left orange ? pill (semantic "question pending"), middle
// provider+summary, right AgentIcon for the waiting session's provider.
// Question is treated as an agent-run state for status purposes, so the
// waiting provider's animated icon is shown on the right rather than the
// music wave that the previous implementation borrowed from
// CompactMusicActivityView.
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

    private var waitingProvider: SessionProvider? {
        primarySession?.provider
    }

    var body: some View {
        HStack(spacing: 8) {
            // Left: orange "?" pill. Same hue as the in-panel question
            // header so the chip and the panel it opens share a colour
            // vocabulary. Size 18x18 matches CompactMusicActivityView's
            // 18x18 artwork placeholder.
            Circle()
                .fill(Color.orange)
                .frame(width: 18, height: 18)
                .overlay(
                    Text("?")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                )

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

            // Right: PermissionIndicatorIcon (the same animated spinner used by
            // the permission close-state indicator), tinted to the
            // waiting session's provider colour. Same visual idiom as
            // permission so the two wait-states read as siblings;
            // semantic for "this agent is currently waiting on something".
            if let provider = waitingProvider {
                PermissionIndicatorIcon(
                    size: 16,
                    color: SessionLoadingStyle.tint(for: provider)
                )
                .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

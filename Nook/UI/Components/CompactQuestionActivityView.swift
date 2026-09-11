// CompactQuestionActivityView.swift
// Nook
//
// Closed-notch chip shown when a session is waiting to answer an AskUserQuestion.
// Three segments: left question-mark, middle provider+summary, right music wave
// (only while music is playing). The middle text is drawn unconditionally — on
// devices with a physical notch the OS covers it, which is the intended look.

import SwiftUI

struct CompactQuestionActivityView: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var musicManager: MusicManager
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

            if musicManager.isVisible {
                Image(systemName: musicManager.playbackState.isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

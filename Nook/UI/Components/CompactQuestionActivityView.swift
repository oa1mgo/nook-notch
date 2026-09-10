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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(providerLabel) · QUESTION")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
                Text(summaryText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            Circle()
                .fill(Color.orange)
                .frame(width: 22, height: 22)
                .overlay(
                    Text("?")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.black)
                )

            if musicManager.isVisible {
                WaveIndicator(isPlaying: musicManager.playbackState.isPlaying)
                    .frame(width: 50, height: 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

struct WaveIndicator: View {
    let isPlaying: Bool
    private let heights: [CGFloat] = [6, 12, 8, 14, 5, 10, 7, 11]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<heights.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 2, height: isPlaying ? heights[i] : 4)
            }
        }
    }
}

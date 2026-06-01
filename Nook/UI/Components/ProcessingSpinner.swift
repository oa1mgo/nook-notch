//
//  ProcessingSpinner.swift
//  Nook
//
//  Animated symbol spinner for processing state
//

import Combine
import SwiftUI

enum SessionLoadingStyle {
    static let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    static let frameDuration: TimeInterval = 0.15

    static func tint(for provider: SessionProvider) -> Color {
        switch provider {
        case .claude:
            return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex:
            return Color(red: 0.35, green: 0.62, blue: 0.96)
        case .opencode:
            return Color(red: 0.40, green: 0.80, blue: 0.40)
        }
    }
}

struct ProcessingSpinner: View {
    let color: Color
    let provider: SessionProvider?
    @State private var phase: Int = 0
    @State private var rotation: Double = 0

    private let timer = Timer.publish(
        every: SessionLoadingStyle.frameDuration,
        on: .main,
        in: .common
    ).autoconnect()

    init(color: Color = SessionLoadingStyle.tint(for: .claude)) {
        self.color = color
        self.provider = nil
    }

    init(provider: SessionProvider) {
        self.color = SessionLoadingStyle.tint(for: provider)
        self.provider = provider
    }

    @ViewBuilder
    var body: some View {
        if provider == .codex {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.18), lineWidth: 1.6)

                Circle()
                    .trim(from: 0.12, to: 0.72)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
            }
            .frame(width: 16, height: 16)
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
        } else {
            Text(SessionLoadingStyle.symbols[phase % SessionLoadingStyle.symbols.count])
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(color)
                .frame(width: 16, alignment: .center)
                .onReceive(timer) { _ in
                    phase = (phase + 1) % SessionLoadingStyle.symbols.count
                }
        }
    }
}

struct SessionLoadingRow: View {
    let provider: SessionProvider
    var turnId: String = ""

    @State private var dotCount: Int = 1

    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    private let baseTexts = ["Processing", "Working"]

    private var tint: Color {
        SessionLoadingStyle.tint(for: provider)
    }

    private var baseText: String {
        let index = abs(turnId.hashValue) % baseTexts.count
        return baseTexts[index]
    }

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ProcessingSpinner(provider: provider)
                .frame(width: 6)

            Text(baseText + dots)
                .font(.system(size: 13))
                .foregroundColor(tint)

            Spacer()
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}

#Preview {
    ProcessingSpinner()
        .frame(width: 30, height: 30)
        .background(.black)
}

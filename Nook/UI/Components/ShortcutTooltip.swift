//
//  ShortcutTooltip.swift
//  Nook
//
//  Custom hover tooltip for the notch NSPanel. SwiftUI `.help()` (system
//  help tags) does not fire inside our borderless nonactivating panel, so
//  every in-panel hint uses this instead: hover for 0.2s, then a small
//  dark bubble follows the cursor. Extracted from duplicated private
//  copies in MusicCardView / PerformanceMonitorViews.
//
//  The bubble flips to stay inside the panel: X auto-flips left when the
//  estimate would cross the host's right edge; `above: true` places it
//  over the host (used by bottom-row controls).

import SwiftUI
import AppKit

struct ShortcutTooltip: ViewModifier {
    let shortcut: String?
    var above: Bool = false

    // Bubble metrics for estimation (must match the Text styling below).
    private static let bubbleFont = Font.system(size: 10, weight: .medium)
    private static let bubbleHPadding: CGFloat = 10   // 5 per side
    private static let bubbleVPadding: CGFloat = 4    // 2 per side
    private static let bubbleHeight: CGFloat = 17     // single-line 10pt text + vpadding
    private static let bubbleGap: CGFloat = 16        // cursor → bubble
    private static let widthSlack: CGFloat = 6        // estimation margin

    @State private var showTooltip = false
    @State private var hoverTask: DispatchWorkItem?
    @State private var hoverPoint: CGPoint = .zero
    @State private var anchorSize: CGSize = .zero

    func body(content: Content) -> some View {
        if let shortcut {
            content
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { anchorSize = geo.size }
                            .onChange(of: geo.size) { _, new in anchorSize = new }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if showTooltip {
                        Text(shortcut)
                            .fixedSize()
                            .font(Self.bubbleFont)
                            .foregroundColor(.white)
                            .padding(.horizontal, Self.bubbleHPadding / 2)
                            .padding(.vertical, Self.bubbleVPadding / 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.black.opacity(0.65))
                            )
                            .offset(x: bubbleOffset.x, y: bubbleOffset.y)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoverPoint = point
                        hoverTask?.cancel()
                        let task = DispatchWorkItem {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showTooltip = true
                            }
                        }
                        hoverTask = task
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
                    case .ended:
                        hoverTask?.cancel()
                        hoverTask = nil
                        withAnimation(.easeInOut(duration: 0.1)) {
                            showTooltip = false
                        }
                    }
                }
                .onDisappear {
                    hoverTask?.cancel()
                    hoverTask = nil
                    showTooltip = false
                }
        } else {
            content
        }
    }

    private var bubbleOffset: CGPoint {
        let text = shortcut ?? ""
        let estW = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).width
            + Self.bubbleHPadding + Self.widthSlack
        var x = hoverPoint.x
        if x + estW > anchorSize.width {
            x = anchorSize.width - estW   // right-align to host; may go negative
        }
        let y = above ? hoverPoint.y - Self.bubbleGap - Self.bubbleHeight
                      : hoverPoint.y + Self.bubbleGap
        return CGPoint(x: x, y: y)
    }
}

extension View {
    func shortcutTooltip(_ shortcut: String?, above: Bool = false) -> some View {
        modifier(ShortcutTooltip(shortcut: shortcut, above: above))
    }
}

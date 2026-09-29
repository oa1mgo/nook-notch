//  ShortcutTooltip.swift
//  Nook
//
//  Custom hover tooltip for the notch NSPanel. SwiftUI `.help()` (system
//  help tags) does not fire inside our borderless nonactivating panel, so
//  every in-panel hint uses this instead: hover for 0.2s, then a small
//  dark bubble follows the cursor. Extracted from duplicated private
//  copies in MusicCardView / PerformanceMonitorViews.

import SwiftUI

struct ShortcutTooltip: ViewModifier {
    let shortcut: String?

    @State private var showTooltip = false
    @State private var hoverTask: DispatchWorkItem?
    @State private var hoverPoint: CGPoint = .zero

    func body(content: Content) -> some View {
        if let shortcut {
            content
                .overlay(alignment: .topLeading) {
                    if showTooltip {
                        Text(shortcut)
                            .fixedSize()
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.black.opacity(0.65))
                            )
                            .offset(x: hoverPoint.x, y: hoverPoint.y + 16)
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
        } else {
            content
        }
    }
}

extension View {
    func shortcutTooltip(_ shortcut: String?) -> some View {
        modifier(ShortcutTooltip(shortcut: shortcut))
    }
}

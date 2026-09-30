//
//  MarqueeText.swift
//  Nook
//
//  A text view that scrolls horizontally when the content overflows
//  the available width. Used in compact list rows (e.g. permission
//  prompts with long file paths) where truncation would hide the
//  important part of the path.
//
//  Layout strategy:
//   1. The text is laid out at its natural (unconstrained) width via
//      .fixedSize(horizontal: true, vertical: false).
//   2. A GeometryReader measures the container width (the space the
//      parent actually allocates to this view).
//   3. A PreferenceKey measures the text's natural width.
//   4. When textWidth > containerWidth, a TimelineView drives a
//      repeating offset that scrolls by (textWidth - containerWidth),
//      pauses, scrolls back, and pauses again.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    /// Seconds for one full cycle: pause → scroll left → pause → scroll back.
    private let cycleDuration: Double = 8.0
    /// Fraction of the cycle spent scrolling (rest is pause at ends).
    private let scrollFraction: Double = 0.6

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var overflow: CGFloat {
        max(0, textWidth - containerWidth)
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                Text(text)
                    .font(font)
                    .foregroundColor(color)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        GeometryReader { textGeo in
                            Color.clear
                                .preference(
                                    key: TextWidthKey.self,
                                    value: textGeo.size.width
                                )
                        }
                    )
                    .offset(x: offset(for: timeline.date))
            }
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { containerWidth = $0 }
        }
        .onPreferenceChange(TextWidthKey.self) { textWidth = $0 }
        .clipped()
        .frame(height: 16)
    }

    private func offset(for date: Date) -> CGFloat {
        guard overflow > 0 else { return 0 }

        let t = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
        let pause = (1.0 - scrollFraction) / 2
        let scrollEnd = pause + scrollFraction

        if t < pause {
            return 0
        } else if t < scrollEnd {
            let p = (t - pause) / scrollFraction
            let eased = p * p * (3 - 2 * p)
            return -(overflow * eased)
        } else if t < scrollEnd + pause {
            return -overflow
        } else {
            let p = (t - scrollEnd - pause) / pause
            let eased = p * p * (3 - 2 * p)
            return -(overflow * (1 - eased))
        }
    }
}

private struct TextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

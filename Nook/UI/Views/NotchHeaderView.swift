//
//  NotchHeaderView.swift
//  Nook
//
//  Header bar for the dynamic island
//

import Combine
import SwiftUI

// MARK: - AgentIcon

/// Provider-aware agent activity icon. Dispatches to the provider's
/// visual identity (ClaudeCrabIcon for Claude, CodexPulseIcon for Codex,
/// CursorLogoIcon for Cursor, SF Symbol for OpenCode). The `animate` parameter controls
/// activity-indicator animations (e.g. leg walking, core pulse).
struct AgentIcon: View {
    let provider: SessionProvider
    var size: CGFloat = 14
    var color: Color = .white
    var animate: Bool = false

    var body: some View {
        switch provider {
        case .claude:
            ClaudeCrabIcon(size: size, color: color, animateLegs: animate)
        case .codex:
            CodexPulseIcon(size: size, color: color, isAnimating: animate)
        case .opencode:
            Image(systemName: provider.systemImage)
                .font(.system(size: size * 0.79, weight: .semibold))
                .foregroundColor(color)
                .frame(width: size, height: size)
        case .cursor:
            CursorLogoIcon(size: size, color: color)
        }
    }
}

struct CursorLogoIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 16, color: Color = Color(red: 0.70, green: 0.70, blue: 0.68)) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Canvas { context, canvasSize in
            let edge = min(canvasSize.width, canvasSize.height)
            let scale = edge / 100
            let xOffset = (canvasSize.width - edge) / 2
            let yOffset = (canvasSize.height - edge) / 2

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
            }

            func polygon(_ points: [CGPoint]) -> Path {
                var path = Path()
                guard let first = points.first else { return path }
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                path.closeSubpath()
                return path
            }

            let top = point(50, 3)
            let upperRight = point(94, 27)
            let lowerRight = point(94, 72)
            let bottom = point(50, 97)
            let lowerLeft = point(6, 72)
            let upperLeft = point(6, 27)
            let center = point(50, 52)

            context.fill(
                polygon([top, upperRight, lowerRight, bottom, lowerLeft, upperLeft]),
                with: .color(Color.black.opacity(0.50))
            )
            context.fill(
                polygon([upperLeft, center, bottom, lowerLeft]),
                with: .color(color.opacity(0.58))
            )
            context.fill(
                polygon([center, lowerRight, bottom]),
                with: .color(color.opacity(0.42))
            )
            context.fill(
                polygon([upperLeft, upperRight, center]),
                with: .color(Color.white.opacity(0.92))
            )
            context.fill(
                polygon([upperRight, point(63, 91), center]),
                with: .color(Color.white.opacity(0.72))
            )
        }
        .frame(width: size, height: size)
    }
}

// MARK: - ClaudeCrabIcon

struct ClaudeCrabIcon: View {
    let size: CGFloat
    let color: Color
    var animateLegs: Bool = false

    @State private var legPhase: Int = 0

    // Timer for leg animation
    private let legTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    init(size: CGFloat = 16, color: Color = Color(red: 0.85, green: 0.47, blue: 0.34), animateLegs: Bool = false) {
        self.size = size
        self.color = color
        self.animateLegs = animateLegs
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 52.0  // Original viewBox height is 52
            let xOffset = (canvasSize.width - 66 * scale) / 2

            // Left antenna
            let leftAntenna = Path { p in
                p.addRect(CGRect(x: 0, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftAntenna, with: .color(color))

            // Right antenna
            let rightAntenna = Path { p in
                p.addRect(CGRect(x: 60, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightAntenna, with: .color(color))

            // Animated legs - alternating up/down pattern for walking effect
            // Legs stay attached to body (y=39), only height changes
            let baseLegPositions: [CGFloat] = [6, 18, 42, 54]
            let baseLegHeight: CGFloat = 13

            // Height offsets: positive = longer leg (down), negative = shorter leg (up)
            let legHeightOffsets: [[CGFloat]] = [
                [3, -3, 3, -3],   // Phase 0: alternating
                [0, 0, 0, 0],     // Phase 1: neutral
                [-3, 3, -3, 3],   // Phase 2: alternating (opposite)
                [0, 0, 0, 0],     // Phase 3: neutral
            ]

            let currentHeightOffsets = animateLegs ? legHeightOffsets[legPhase % 4] : [CGFloat](repeating: 0, count: 4)

            for (index, xPos) in baseLegPositions.enumerated() {
                let heightOffset = currentHeightOffsets[index]
                let legHeight = baseLegHeight + heightOffset
                let leg = Path { p in
                    p.addRect(CGRect(x: xPos, y: 39, width: 6, height: legHeight))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                context.fill(leg, with: .color(color))
            }

            // Main body
            let body = Path { p in
                p.addRect(CGRect(x: 6, y: 0, width: 54, height: 39))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(body, with: .color(color))

            // Left eye
            let leftEye = Path { p in
                p.addRect(CGRect(x: 12, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftEye, with: .color(.black))

            // Right eye
            let rightEye = Path { p in
                p.addRect(CGRect(x: 48, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightEye, with: .color(.black))
        }
        .frame(width: size * (66.0 / 52.0), height: size)
        .onReceive(legTimer) { _ in
            if animateLegs {
                legPhase = (legPhase + 1) % 4
            }
        }
    }
}

struct CodexPulseIcon: View {
    let size: CGFloat
    let color: Color
    var isAnimating: Bool = false

    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    init(size: CGFloat = 16, color: Color = Color(red: 0.34, green: 0.64, blue: 0.98), isAnimating: Bool = false) {
        self.size = size
        self.color = color
        self.isAnimating = isAnimating
    }

    private let shellPixels: [(CGFloat, CGFloat)] = [
        (4, 4), (8, 4), (12, 4), (16, 4), (20, 4),
        (4, 8), (20, 8),
        (4, 12), (20, 12),
        (4, 16), (20, 16),
        (4, 20), (8, 20), (12, 20), (16, 20), (20, 20)
    ]

    private let coreFrames: [[(CGFloat, CGFloat)]] = [
        [(8, 8), (12, 8), (16, 8), (12, 12), (12, 16)],
        [(8, 8), (16, 8), (8, 16), (16, 16), (12, 12)],
        [(12, 8), (8, 12), (16, 12), (12, 16), (12, 12)],
        [(8, 8), (12, 8), (16, 8), (8, 16), (16, 16)]
    ]

    var body: some View {
        Canvas { context, _ in
            let scale = size / 24.0
            let pixelSize: CGFloat = 4 * scale
            let glowColor = color.opacity(isAnimating ? 0.35 : 0.2)

            for (x, y) in shellPixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(roundedRect: rect.insetBy(dx: -0.4, dy: -0.4), cornerRadius: pixelSize * 0.18), with: .color(glowColor))
                context.fill(Path(rect), with: .color(color))
            }

            let frame = coreFrames[phase % coreFrames.count]
            for (x, y) in frame {
                let intensity = isAnimating ? 1.0 : 0.75
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(roundedRect: rect.insetBy(dx: -0.8, dy: -0.8), cornerRadius: pixelSize * 0.22), with: .color(color.opacity(0.32 * intensity)))
                context.fill(Path(rect), with: .color(color.opacity(intensity)))
            }
        }
        .frame(width: size, height: size)
        .onReceive(timer) { _ in
            if isAnimating {
                phase = (phase + 1) % coreFrames.count
            }
        }
    }
}

// Pixel art permission indicator icon
struct PermissionIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = Color(red: 0.11, green: 0.12, blue: 0.13)) {
        self.size = size
        self.color = color
    }

    // Visible pixel positions from the SVG (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (7, 7), (7, 11),           // Left column
        (11, 3),                    // Top left
        (15, 3), (15, 19), (15, 27), // Center column
        (19, 3), (19, 15),          // Right of center
        (23, 7), (23, 11)           // Right column
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

// Pixel art "ready for input" indicator icon (checkmark/done shape)
struct ReadyForInputIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = TerminalColors.green) {
        self.size = size
        self.color = color
    }

    // Checkmark shape pixel positions (at 30x30 scale)
    private let pixels: [(CGFloat, CGFloat)] = [
        (5, 15),                    // Start of checkmark
        (9, 19),                    // Down stroke
        (13, 23),                   // Bottom of checkmark
        (17, 19),                   // Up stroke begins
        (21, 15),                   // Up stroke
        (25, 11),                   // Up stroke
        (29, 7)                     // End of checkmark
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 30.0
            let pixelSize: CGFloat = 4 * scale

            for (x, y) in pixels {
                let rect = CGRect(
                    x: x * scale - pixelSize / 2,
                    y: y * scale - pixelSize / 2,
                    width: pixelSize,
                    height: pixelSize
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: size, height: size)
    }
}

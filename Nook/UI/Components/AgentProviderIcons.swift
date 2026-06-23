//
//  AgentProviderIcons.swift
//  Nook
//
//  Provider-specific activity and logo icons.
//

import Combine
import SwiftUI

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
            CodexLogoIcon(size: size, color: color, isAnimating: animate)
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

struct ClaudeCrabIcon: View {
    let size: CGFloat
    let color: Color
    var animateLegs: Bool = false

    @State private var legPhase: Int = 0

    private let legTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    init(size: CGFloat = 16, color: Color = Color(red: 0.85, green: 0.47, blue: 0.34), animateLegs: Bool = false) {
        self.size = size
        self.color = color
        self.animateLegs = animateLegs
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 52.0
            let xOffset = (canvasSize.width - 66 * scale) / 2

            let leftAntenna = Path { path in
                path.addRect(CGRect(x: 0, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftAntenna, with: .color(color))

            let rightAntenna = Path { path in
                path.addRect(CGRect(x: 60, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightAntenna, with: .color(color))

            let baseLegPositions: [CGFloat] = [6, 18, 42, 54]
            let baseLegHeight: CGFloat = 13
            let legHeightOffsets: [[CGFloat]] = [
                [3, -3, 3, -3],
                [0, 0, 0, 0],
                [-3, 3, -3, 3],
                [0, 0, 0, 0],
            ]
            let currentHeightOffsets = animateLegs ? legHeightOffsets[legPhase % 4] : [CGFloat](repeating: 0, count: 4)

            for (index, xPos) in baseLegPositions.enumerated() {
                let heightOffset = currentHeightOffsets[index]
                let legHeight = baseLegHeight + heightOffset
                let leg = Path { path in
                    path.addRect(CGRect(x: xPos, y: 39, width: 6, height: legHeight))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                context.fill(leg, with: .color(color))
            }

            let body = Path { path in
                path.addRect(CGRect(x: 6, y: 0, width: 54, height: 39))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(body, with: .color(color))

            let leftEye = Path { path in
                path.addRect(CGRect(x: 12, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftEye, with: .color(.black))

            let rightEye = Path { path in
                path.addRect(CGRect(x: 48, y: 13, width: 6, height: 6.5))
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

struct CodexLogoIcon: View {
    let size: CGFloat
    let color: Color
    var isAnimating: Bool = false

    @State private var pulse = false

    init(size: CGFloat = 16, color: Color = Color(red: 0.34, green: 0.64, blue: 0.98), isAnimating: Bool = false) {
        self.size = size
        self.color = color
        self.isAnimating = isAnimating
    }

    var body: some View {
        Canvas { context, canvasSize in
            let edge = min(canvasSize.width, canvasSize.height)
            let scale = edge / 100
            let xOffset = (canvasSize.width - edge) / 2
            let yOffset = (canvasSize.height - edge) / 2

            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(
                    x: xOffset + x * scale,
                    y: yOffset + y * scale,
                    width: width * scale,
                    height: height * scale
                )
            }

            func roundedRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat) -> Path {
                Path(roundedRect: rect(x, y, width, height), cornerRadius: radius * scale)
            }

            let glowOpacity = isAnimating && pulse ? 0.38 : 0.24
            context.addFilter(.shadow(color: color.opacity(glowOpacity), radius: 7 * scale, x: 0, y: 0))

            let top = Path(ellipseIn: rect(18, 6, 46, 40))
            let right = Path(ellipseIn: rect(48, 16, 39, 42))
            let left = Path(ellipseIn: rect(8, 30, 38, 42))
            let bottom = Path(ellipseIn: rect(23, 48, 52, 38))
            let body = roundedRect(18, 31, 64, 48, radius: 18)
            let fill = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    color.opacity(0.88),
                    Color(red: 0.31, green: 0.35, blue: 1.0),
                    color.opacity(0.96),
                ]),
                startPoint: CGPoint(x: xOffset + 18 * scale, y: yOffset + 8 * scale),
                endPoint: CGPoint(x: xOffset + 72 * scale, y: yOffset + 88 * scale)
            )

            for shape in [top, right, left, bottom, body] {
                context.fill(shape, with: fill)
            }

            context.stroke(Path(ellipseIn: rect(19, 7, 44, 38)), with: .color(.white.opacity(0.22)), lineWidth: 1.6 * scale)

            let promptStroke = StrokeStyle(lineWidth: 10 * scale, lineCap: .round, lineJoin: .round)
            var chevron = Path()
            chevron.move(to: CGPoint(x: xOffset + 34 * scale, y: yOffset + 34 * scale))
            chevron.addLine(to: CGPoint(x: xOffset + 46 * scale, y: yOffset + 50 * scale))
            chevron.addLine(to: CGPoint(x: xOffset + 34 * scale, y: yOffset + 66 * scale))
            context.stroke(chevron, with: .color(.white.opacity(0.92)), style: promptStroke)

            var cursor = Path()
            cursor.move(to: CGPoint(x: xOffset + 57 * scale, y: yOffset + 66 * scale))
            cursor.addLine(to: CGPoint(x: xOffset + 75 * scale, y: yOffset + 66 * scale))
            context.stroke(cursor, with: .color(.white.opacity(0.92)), style: promptStroke)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard isAnimating else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: isAnimating) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                pulse = false
            }
        }
    }
}

/// OpenCode brand mark: a square ring (16×20 outer minus 8×12 inner
/// hole, drawn with even-odd fill). Sourced directly from the
/// project's official SVG asset; the 24×24 viewBox is preserved but
/// the icon is fit-to-box scaled so it sits in a `size` × `size`
/// frame without overflowing.
struct OpenCodeLogoIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 16, color: Color = .white) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Canvas { context, canvasSize in
            // Source SVG coordinates (24×24 viewBox):
            //   outer: (4, 2) → (20, 22)   = 16 × 20
            //   inner: (8, 6) → (16, 18)   =  8 × 12 (the hole)
            // Translate to origin: outer (0,0)→(16,20), inner (4,4)→(12,16).
            //
            // Fit-to-box: keep the 16:20 aspect ratio; the shorter
            // dimension dictates the scale. For a 16×16 frame that
            // means scale = 16/20 = 0.8 → final icon 12.8×16, ring
            // thickness 4×0.8 = 3.2 units.
            let pathW: CGFloat = 16
            let pathH: CGFloat = 20
            let scale = min(canvasSize.width / pathW, canvasSize.height / pathH)
            let drawW = pathW * scale
            let drawH = pathH * scale
            let xOffset = (canvasSize.width - drawW) / 2
            let yOffset = (canvasSize.height - drawH) / 2

            let outer = CGRect(x: xOffset, y: yOffset, width: drawW, height: drawH)
            let inner = CGRect(
                x: xOffset + 4 * scale,
                y: yOffset + 4 * scale,
                width: 8 * scale,
                height: 12 * scale
            )

            var path = Path()
            path.addRect(outer)
            path.addRect(inner)
            context.fill(path, with: .color(color), style: FillStyle(eoFill: true))
        }
        .frame(width: size, height: size)
    }
}

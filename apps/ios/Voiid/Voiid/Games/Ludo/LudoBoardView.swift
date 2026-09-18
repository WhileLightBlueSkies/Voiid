//
//  LudoBoardView.swift
//  Voiid
//
//  The luxury wood & brass board canvas with animated pawns and pulsing move hints.
//

import SwiftUI

// MARK: - Static board

struct BoardCanvas: View {
    let unit: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            let u = unit
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * u, y: y * u, width: w * u, height: h * u)
            }
            func cell(_ r: CGRect, _ fill: Color) {
                ctx.fill(Path(r), with: .color(fill))
                ctx.stroke(Path(r), with: .color(Theme.line), lineWidth: 0.5)
            }

            // Yards
            for (i, seat) in LudoEngine.seats.enumerated() {
                let o = seat.yardOrigin
                let outer = rect(CGFloat(o.x), CGFloat(o.y), 6, 6)
                ctx.fill(Path(roundedRect: outer, cornerRadius: u * 0.18),
                         with: .color(Theme.seat(i)))

                let inner = rect(CGFloat(o.x) + 1, CGFloat(o.y) + 1, 4, 4)
                ctx.fill(Path(roundedRect: inner, cornerRadius: u * 0.14),
                         with: .color(Theme.board))
                ctx.stroke(Path(roundedRect: inner, cornerRadius: u * 0.14),
                           with: .color(Theme.line), lineWidth: 0.5)

                for slot in LudoEngine.yardSlots {
                    let d = rect(CGFloat(o.x) + slot.x - 0.42,
                                 CGFloat(o.y) + slot.y - 0.42, 0.84, 0.84)
                    ctx.fill(Path(ellipseIn: d), with: .color(Theme.board2))
                    ctx.stroke(Path(ellipseIn: d), with: .color(Theme.line), lineWidth: 0.5)
                }
            }

            // Ring
            for (index, p) in LudoEngine.ring.enumerated() {
                let r = rect(CGFloat(p.x), CGFloat(p.y), 1, 1)
                let owner = LudoEngine.seats.firstIndex { $0.start == index }
                cell(r, owner.map { Theme.seat($0) } ?? Theme.board)

                if LudoEngine.safeSquares.contains(index), owner == nil {
                    ctx.stroke(starPath(in: r.insetBy(dx: r.width * 0.19, dy: r.height * 0.19)),
                               with: .color(Color(ludoHex: 0x6B5B44).opacity(0.55)),
                               style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
            }

            // Home columns
            for (i, seat) in LudoEngine.seats.enumerated() {
                for p in seat.column {
                    cell(rect(CGFloat(p.x), CGFloat(p.y), 1, 1), Theme.seat(i).opacity(0.88))
                }
            }

            // Centre rosette
            let core = rect(6, 6, 3, 3)
            cell(core, Theme.board2)
            let c = CGPoint(x: 7.5 * u, y: 7.5 * u)
            let corners = [
                CGPoint(x: 6.5 * u, y: 6.5 * u), CGPoint(x: 8.5 * u, y: 6.5 * u),
                CGPoint(x: 8.5 * u, y: 8.5 * u), CGPoint(x: 6.5 * u, y: 8.5 * u)
            ]
            let wedges: [(Int, Int, Int)] = [(0, 3, 0), (1, 0, 1), (2, 1, 2), (3, 2, 3)]
            for (seat, a, b) in wedges {
                var path = Path()
                path.move(to: c)
                path.addLine(to: corners[a])
                path.addLine(to: corners[b])
                path.closeSubpath()
                ctx.fill(path, with: .color(Theme.seat(seat)))
            }
        }
        .background(Theme.board)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.brass.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.85), radius: 30, y: 22)
    }

    private func starPath(in r: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let outer = min(r.width, r.height) / 2
        let inner = outer * 0.45
        for i in 0..<10 {
            let radius = i.isMultiple(of: 2) ? outer : inner
            let angle = -.pi / 2 + Double(i) * .pi / 5
            let pt = CGPoint(x: c.x + radius * cos(angle), y: c.y + radius * sin(angle))
            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Token

struct TokenView: View {
    let seat: Int
    let diameter: CGFloat
    let isLive: Bool
    let isHopping: Bool
    let isPopping: Bool

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isLive {
                // Grounded selection ring at the pawn's base
                Circle()
                    .strokeBorder(Theme.seat(seat), lineWidth: 2)
                    .frame(width: diameter * 1.36, height: diameter * 1.36)
                    .scaleEffect(reduceMotion ? 1.05 : (pulse ? 1.2 : 0.95))
                    .opacity(reduceMotion ? 0.85 : (pulse ? 0.15 : 0.9))

                Circle()
                    .strokeBorder(.white.opacity(0.75), lineWidth: 1.2)
                    .frame(width: diameter * 1.16, height: diameter * 1.16)

                // Downward pointer arrow indicating selectable pawn
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: max(8, diameter * 0.32), weight: .bold))
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                    .offset(y: -diameter * 0.74 + (pulse ? -2 : 1))
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }

            Circle()
                .fill(Theme.seat(seat))
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(.white.opacity(0.55))
                        .frame(width: diameter * 0.3, height: diameter * 0.3)
                        .blur(radius: diameter * 0.08)
                        .offset(x: diameter * 0.18, y: diameter * 0.14)
                }
                .overlay {
                    Circle().fill(.white.opacity(0.92))
                        .frame(width: diameter * 0.34, height: diameter * 0.34)
                }
                .overlay { Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5) }
                .frame(width: diameter, height: diameter)
                .shadow(color: isLive ? Theme.seat(seat).opacity(0.7) : .black.opacity(0.5),
                        radius: isLive ? 6 : 3, y: isLive ? 1 : 2)
                .scaleEffect(isPopping ? 1.45 : (isHopping ? 1.12 : (isLive ? (pulse ? 1.06 : 0.98) : 1)))
                .offset(y: isHopping ? -diameter * 0.35 : 0)
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.5), value: isHopping)
        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: isPopping)
        .onChange(of: isLive, initial: true) { _, live in
            pulse = false
            guard live, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Move hint

struct MoveHint: View {
    let seat: Int
    let unit: CGFloat
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(.white.opacity(0.85), lineWidth: 2)
            .background {
                Circle()
                    .fill(Theme.seat(seat).opacity(0.75))
                    .padding(unit * 0.24)
            }
            .frame(width: unit * 0.88, height: unit * 0.88)
            // Holds at full opacity rather than pulsing: this marks where a token may land,
            // so it has to stay legible when the animation is suppressed.
            .opacity(reduceMotion ? 1 : (pulse ? 1 : 0.45))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .allowsHitTesting(false)
    }
}

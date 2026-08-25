//
//  LudoPlayerPod.swift
//  Voiid
//
//  A player pod (§11.2): EXACTLY two visible elements — the timer-ring/color-chip assembly at
//  its outer edge and one username line. The ring SURROUNDS the chip rather than adding a third
//  ornament. No avatar, badge, level, rank, gift, coin, completion dots, scores or status icons;
//  finished pawns stay visible in the center triangle instead.
//
//  USERNAME RULES: one line, tail-truncated at 18 clusters, never below 12pt, never marquee.
//  The viewer's own pod shows their username, not "You". Waiting seat: outlined chip +
//  "Waiting…". Dropped seat: keeps position, desaturated chip, name at 55%, no timer.
//

import SwiftUI

struct LudoPlayerPod: View {
    let seatView: LudoSeatViewV2?
    let active: Bool
    /// 0…1 remaining while THIS seat's decision window is open; nil otherwise.
    let ringFraction: Double?
    /// Warning/critical override for the arc; nil → the player hue.
    let ringColorOverride: Color?
    var compact = false
    var accessibilityLabel: String = ""

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = LudoColors.resolve(scheme)
        let size = compact ? LudoDimens.podSizeCompact : LudoDimens.podSizeStandard
        let ring = compact ? LudoDimens.ringCompact : LudoDimens.ringStandard
        let chip = compact ? LudoDimens.chipCompact : LudoDimens.chipStandard

        HStack(spacing: 6) {
            ZStack {
                // Ring surrounds the color chip — never a third ornament (§11.2).
                LudoTimerRing.drawView(
                    diameter: ring,
                    stroke: LudoDimens.ringStroke,
                    track: colors.timerTrack,
                    arc: arcColor(colors),
                    fraction: active ? (ringFraction ?? 1) : nil)
                    .frame(width: ring, height: ring)
                Circle()
                    .strokeBorder(outlined ? colors.yardPocketBorder : .clear, lineWidth: 1)
                    .background(Circle().fill(chipColor(colors)))
                    .frame(width: chip, height: chip)
            }
            .padding(.leading, (size.height - ring) / 2)

            Text(usernameLine)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
        }
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: LudoDimens.podCornerRadius)
                .fill(colors.podSurface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var usernameLine: String {
        guard let sv = seatView else { return "" }
        if sv.participation == "waiting" { return "Waiting…" }
        let name = String(sv.displayName.prefix(18))
        return sv.isBot ? "\(name) BOT" : name
    }

    private var outlined: Bool {
        seatView == nil || seatView?.participation == "waiting"
    }

    private func chipColor(_ c: LudoColors) -> Color {
        guard let sv = seatView else { return .clear }
        return outlined ? .clear : c.hue(sv.seat)
    }

    private func arcColor(_ c: LudoColors) -> Color {
        guard active else { return c.timerTrack }          // inactive pods draw only the track
        if let o = ringColorOverride { return o }
        return c.timerActive
    }
}

private extension LudoTimerRing {
    /// View wrapper so pods can drop the ring straight into a frame. Inactive pods draw ONLY
    /// the neutral track circle; an active pod replaces that track progressively with the
    /// depleting arc (§11.2).
    static func drawView(diameter: CGFloat, stroke: CGFloat,
                         track: Color, arc: Color, fraction: Double?) -> some View {
        Canvas { ctx, size in
            var ctx = ctx
            draw(&ctx, diameter: min(size.width, size.height), stroke: stroke,
                 track: track,
                 arc: fraction != nil ? arc : .clear,
                 fraction: fraction ?? 0)
        }
        .frame(width: diameter, height: diameter)
    }
}

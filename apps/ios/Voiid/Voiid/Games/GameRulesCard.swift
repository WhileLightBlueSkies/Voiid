//
//  GameRulesCard.swift
//  Voiid
//
//  The "HOW IT'S PLAYED" card, in one place, because two screens now draw it.
//
//  ── WHY THIS FILE EXISTS ────────────────────────────────────────────────────────
//  `GameEntryFlow` built this card first, as a private `@ViewBuilder` on the flow. Then
//  `GameDetailScreen` — the pushed screen reached from a game card's CTA — needed the same
//  card, and a player who meets the rules on both surfaces must meet the SAME rules, laid out
//  the same way. Two copies of a layout drift: one gets a spacing fix, the other does not, and
//  the product reads as two products (§4 Familiarity — things that look the same must behave
//  the same). So the presentation lives here and both callers draw it.
//
//  ── WHAT VARIES BETWEEN THE TWO CALLERS, AND WHAT DOES NOT ──────────────────────
//  The LOOK does not vary: same heading, same 18pt icon column, same 13pt body, same card fill.
//  What varies is HOW MUCH FITS, and that is a property of the SURFACE, not of the rules:
//
//  * A SHEET has a hard ceiling. `GameEntryFlow` must keep its play options reachable without
//    scrolling on a 667pt device, so five of the six rule sets have to fold behind a disclosure
//    there — see its `previewCount`. The rules collapse; the buttons never do.
//  * A PUSHED SCREEN with a pinned footer has no such ceiling. `GameDetailScreen` overlays its
//    buttons on a ZStack and reserves their height with `.contentMargins(.bottom, 132)`, so the
//    content scrolls UNDERNEATH controls that never move. Nothing the card does can push a
//    button off screen, because the buttons are not in the scrolling column at all.
//
//  Hence `previewCount`: a caller that has a budget passes one, and a caller that does not
//  passes nil for "show everything, draw no disclosure". The card does not guess which surface
//  it is on — the surface tells it, because only the surface knows.
//
//  NOTHING IS EVER FABRICATED. A slug with no lines in `GameRules` renders NO CARD — not a
//  heading over an empty box, not an invented sentence to fill it. All six catalog slugs
//  (cricket, tictactoe, rps, snake, seabattle, ludo) have rules written today; a seventh added
//  to the server without rules would simply show none here until someone writes them.
//

import SwiftUI

/// The rules for one game, as a card.
///
/// ITS OWN VIEW rather than a function on either caller, because the disclosure needs `@State`
/// of its own. Hoisting `rulesExpanded` onto a parent would make the expansion a property of
/// the screen rather than of the card, and the state would survive a game change.
struct GameRulesCard: View {

    let slug: String

    /// How many lines to show before the player asks for the rest, or nil for ALL of them with
    /// no disclosure row drawn at all.
    ///
    /// NIL IS NOT A DEFAULT SO MUCH AS AN ASSERTION: the caller is stating that its surface has
    /// no vertical budget to protect. `GameDetailScreen` passes nil because its buttons are
    /// pinned over a scroll view; a sheet with buttons in the scrolling column must pass a
    /// count. See the file note.
    var previewCount: Int?

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lines = GameRules.lines(for: slug)
        // NEVER FABRICATED. A game with no rules written shows no rules card at all, rather
        // than a heading over an empty box or a sentence invented to fill it.
        if !lines.isEmpty {
            // The full set when the caller set no budget, or when the budget covers it all;
            // otherwise as much of the opening as the budget affords — which on the most
            // crowded sheets is none of it, leaving the card as a single row that opens them.
            let budget = previewCount ?? lines.count
            let collapsible = budget < lines.count
            let shown = (collapsible && !expanded) ? Array(lines.prefix(budget)) : lines
            let hidden = lines.count - shown.count

            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                Text("How it's played")
                    .font(VoiidFont.rounded(12, .bold))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(VoiidColor.textSecondary)

                ForEach(shown) { line in
                    HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                        Image(systemName: line.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VoiidColor.primary)
                            // Fixed width so the text edges form a column; ragged icons make a
                            // list read as clutter rather than as structure.
                            .frame(width: 18, alignment: .center)
                        Text(line.text)
                            .font(VoiidFont.rounded(13, .regular))
                            .foregroundStyle(VoiidColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if collapsible {
                    Button {
                        Haptics.tap()
                        // A SPRING ON A STATE FLAG, NOT A SCRIPT (§3, §4). The layout settles
                        // toward a new size and can be interrupted, re-tapped and reversed
                        // mid-flight — tap it closed while it is still opening and it turns
                        // around from where it is, because a spring animates from the
                        // presentation value. Critically damped: nothing was thrown here, so an
                        // overshoot would be motion the gesture did not earn.
                        withAnimation(reduceMotion ? nil
                                                   : .spring(response: 0.4,
                                                             dampingFraction: 1.0)) {
                            expanded.toggle()
                        }
                    } label: {
                        HStack(spacing: VoiidSpacing.xs) {
                            // "5 more rules" is only true when some are already showing. When
                            // the budget affords none the row IS the rules, and it has to say
                            // so rather than claim to extend a list that is not there.
                            Text(expanded
                                 ? "Show less"
                                 : shown.isEmpty
                                     ? "Read the \(hidden) rules"
                                     : "\(hidden) more rule\(hidden == 1 ? "" : "s")")
                                .font(VoiidFont.rounded(13, .semibold))
                            // HINTS IN THE DIRECTION OF THE GESTURE (§8): points down at the
                            // rules it will reveal, and turns to point back up at the ones it
                            // will fold away.
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .foregroundStyle(VoiidColor.primary)
                        .padding(.top, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: expanded)
                    .accessibilityLabel(expanded ? "Show fewer rules" : "Show all rules")
                }
            }
            .padding(VoiidSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .fill(VoiidColor.fieldFill.opacity(0.5)))
        }
    }
}

//
//  GameSettingsCard.swift
//  Voiid
//
//  The PER-GAME settings card on `GameDetailScreen` — and the gate that decides whether a
//  given game has one at all.
//
//  ── WHY THIS IS SEPARATE FROM THE GAMES-WIDE SETTINGS SCREEN ────────────────────
//  Sound, haptics and per-game visibility apply to every game Voiid ships, so they live on
//  the arcade-wide screen behind the Games header's `slider.horizontal.3` button
//  (`Games/GameSettingsView.swift`). A steering scheme applies to exactly one game,
//  and burying that distinction is what the old combined sheet did — it put "Snake" as a
//  section header inside a screen called "Game settings" and left players hunting for why
//  the setting did nothing in cricket. Scope now matches location: a setting for one game
//  is on that game's screen, where it cannot be misread as global.
//
//  ── THE GATE IS A SWITCH, AND THAT IS THE POINT ─────────────────────────────────
//  `GameSettingsCard` switches on slug and returns a view. Today exactly one case is
//  populated — Snake — and `default` returns `EmptyView`, which renders NOTHING: no empty
//  card, no disabled row, no "no settings for this game" placeholder. A section that exists
//  only to say it is empty is worse than no section.
//
//  Adding Ludo's first per-game setting later is one `case "ludo":` here plus the view it
//  returns. It is not a redesign of GameDetailScreen, because that screen asks only
//  `GameSettingsCard(slug:)` and never learns which games have settings.
//
//  ── PERSISTENCE IS UNCHANGED ────────────────────────────────────────────────────
//  The steering picker reads and writes `SnakeChoiceStore.controlScheme`, which is the same
//  static, over the same "voiid.snake.control" key, storing the same `ControlScheme`
//  rawValue string, that the old sheet used. A player who picked Swipe still has Swipe.
//

import SwiftUI

/// The per-game settings card, or nothing.
///
/// Renders `EmptyView` for any game with no per-game settings, so a caller can place it
/// unconditionally and get correct layout either way — an `EmptyView` contributes no height
/// and no spacing to the enclosing stack.
struct GameSettingsCard: View {
    let slug: String

    /// Whether this slug has any per-game settings. Exposed so a caller that needs to make a
    /// LAYOUT decision — padding above the card, say — can ask without rendering it first.
    /// Kept in lockstep with the switch below: a new case there needs its slug here.
    static func hasSettings(_ slug: String) -> Bool {
        switch slug {
        case "snake": return true
        default:      return false
        }
    }

    var body: some View {
        switch slug {
        case "snake":
            SnakeSteeringCard()
        default:
            // NOTHING. Not an empty card, not a disabled row.
            EmptyView()
        }
    }
}

// MARK: - Snake

/// Snake's steering scheme — the app's only per-game setting today.
///
/// CROSS_CUTTING.md §12 listed this as missing and the competitor audit found two control
/// schemes are table stakes rather than a nicety (docs/games/SNAKE_COMPETITIVE_PARITY.md
/// §2.5): one joystick is a bet that every thumb is the same.
private struct SnakeSteeringCard: View {
    // A @State mirror rather than a direct binding, because `SnakeChoiceStore` is a plain
    // UserDefaults-backed static and not observable — the same reason the old sheet kept one.
    @State private var control = SnakeChoiceStore.controlScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steering")
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(VoiidColor.textPrimary)

            Picker("Steering", selection: $control) {
                ForEach(SnakeChoiceStore.ControlScheme.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: control) { _, new in
                SnakeChoiceStore.controlScheme = new
                Haptics.tap()
            }

            // The chosen scheme explains itself, so the two words on the segments do not have
            // to carry the whole meaning of the control.
            Text(control.detail)
                .font(VoiidFont.rounded(12))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // SAYS WHEN IT TAKES EFFECT, because it does not take effect now. The arena reads
            // the scheme once on open so the controls cannot move out from under a thumb
            // mid-match, and a setting that appears to do nothing is worse than one that
            // explains its own timing.
            Text("Applies to your next match.")
                .font(VoiidFont.rounded(12))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .padding(VoiidSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1)
        )
    }
}

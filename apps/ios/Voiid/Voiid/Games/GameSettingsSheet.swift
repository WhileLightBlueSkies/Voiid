//
//  GameSettingsSheet.swift
//  Voiid
//
//  Sound and haptics toggles for the Games tab (docs/games/CROSS_CUTTING.md §12).
//
//  There were no game settings of any kind. `GameAudio.isMuted` already existed and already
//  persisted — it simply had no UI, so the only way to silence a match was to silence the
//  phone. That was liveable while the palette was a handful of synthesised bleeps; with a
//  stadium crowd running under every cricket match it is not.
//
//  Sound and haptics came first, because shipping realistic audio made them necessary. The
//  Snake steering scheme joined them once the competitor audit showed two control schemes are
//  table stakes rather than a nicety (docs/games/SNAKE_COMPETITIVE_PARITY.md §2.5).
//
//  §12 also lists a left/right-handed layout and a graphics-quality tier. Both are real
//  settings for real problems and neither is here yet — this sheet grows when something makes
//  a setting necessary, not to pre-empt one.
//
//  Mirrors Android `GameSettingsSheet.kt`.
//
//  ── SUPERSEDED ON THE SHIPPING TAB. DO NOT ADD SETTINGS HERE. ───────────────────
//  This sheet's whole premise — one surface holding both global and per-game settings — is
//  the thing that got split. `RootTabView` renders `GamesScreen`, and that screen's header
//  settings button is gone; the two scopes now live where their scope actually is:
//
//    global (sound, haptics)   → the Games tab header, `Games/GameSettingsView.swift`
//    per-game (Snake steering) → that game's detail screen, `Games/Reference/GameSettingsCard.swift`
//
//  The file survives only because `GamesHomeView` — the older, non-rendered games home kept
//  as the reference implementation for the match plumbing — still presents it, and deleting
//  it would break that file's build. A new setting added here would be invisible to every
//  shipping user. Add it in one of the two files above instead.
//
//  Persistence is shared with those two screens, not duplicated: all three read and write
//  the same `GameAudio.isMuted`, `GameHaptics.isDisabled` and `SnakeChoiceStore.controlScheme`
//  statics over the same UserDefaults keys, so nothing can disagree about a player's choice.
//

import SwiftUI

struct GameSettingsSheet: View {
    var onClose: () -> Void

    // Seeded from the persisted values on appear rather than bound directly to them: the
    // stores are plain UserDefaults-backed statics, not observable, so a @State mirror is what
    // makes the switches move.
    @State private var soundOn = !GameAudio.isMuted
    @State private var hapticsOn = !GameHaptics.isDisabled
    @State private var control = SnakeChoiceStore.controlScheme

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(icon: "speaker.wave.2.fill",
                        title: "Sound",
                        subtitle: "Crowd, chalk, and everything else in a match",
                        isOn: $soundOn)
                        .onChange(of: soundOn) { _, on in
                            GameAudio.isMuted = !on
                            // Silence anything already ringing out — a crowd bed that keeps
                            // playing after the switch flips reads as the setting not working.
                            if !on { GameAudio.shared.stopAll() }
                            // The confirming tap fires only when turning sound ON. Turning it
                            // off and being answered by the device is a small joke at the
                            // player's expense.
                            if on { Haptics.tap() }
                        }

                    row(icon: "iphone.radiowaves.left.and.right",
                        title: "Haptics",
                        subtitle: "Buzz on eats, kills and wickets",
                        isOn: $hapticsOn)
                        .onChange(of: hapticsOn) { _, on in
                            GameHaptics.isDisabled = !on
                            // Fired AFTER the write, so switching haptics on demonstrates
                            // itself and switching them off is silent — the setting proving it
                            // took effect.
                            if on { Haptics.tap() }
                        }
                } footer: {
                    // SAYS WHAT IS ACTUALLY TRUE. This used to promise the silent switch was
                    // respected, which stopped being the case when the session moved to
                    // `.playback` — a game is media and rides the media slider, like every
                    // other game on the store. The call rule is unchanged and still absolute.
                    Text("Games play at your media volume, even on silent. They never play over a call.")
                        .font(VoiidFont.rounded(12, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                .listRowBackground(VoiidColor.surfaceCard)

                // SNAKE ONLY, and labelled as such. Sound and haptics above apply to every
                // game; a control scheme applies to exactly one, and burying that distinction
                // would have players hunting for why the setting did nothing in cricket.
                Section {
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

                    Text(control.detail)
                        .font(VoiidFont.rounded(12, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                } header: {
                    Text("Snake")
                        .font(VoiidFont.rounded(12, .semibold))
                        .foregroundStyle(VoiidColor.textSecondary)
                } footer: {
                    // Says WHEN it takes effect, because it does not take effect now. The
                    // arena reads the scheme once on open so the controls cannot move out from
                    // under a thumb mid-match, and a setting that appears to do nothing is
                    // worse than one that explains its own timing.
                    Text("Applies to your next match.")
                        .font(VoiidFont.rounded(12, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                .listRowBackground(VoiidColor.surfaceCard)
            }
            .scrollContentBackground(.hidden)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Game settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onClose() }
                        .foregroundStyle(VoiidColor.primary)
                }
            }
        }
    }

    private func row(icon: String, title: String, subtitle: String,
                     isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: VoiidSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(isOn.wrappedValue ? VoiidColor.primary : VoiidColor.textSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundStyle(VoiidColor.textPrimary)
                    Text(subtitle)
                        .font(VoiidFont.rounded(12, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
            }
        }
        .tint(VoiidColor.primary)
    }
}

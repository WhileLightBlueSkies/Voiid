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
//  ── THIS IS THE SETTINGS SURFACE AGAIN. ─────────────────────────────────────────
//  It was briefly split into a per-tab screen and a per-game card. Both of those files are
//  gone, and `GamesScreen`, `LudoGameView` and `SnakeGameView` all present this sheet, so it
//  is once more the single place a player changes any of this.
//
//  A setting added here must be READ by the game it claims to affect. Steering shipped
//  written-but-never-read once already: the value reached UserDefaults and the running match
//  ignored it, which reads to a player as a broken switch rather than a missing feature.
//

import SwiftUI

struct GameSettingsSheet: View {
    var onClose: () -> Void
    /// Snake's steering is shown only where it applies. Offering it inside a Ludo match is a
    /// control that visibly does nothing, which is what makes a settings screen feel broken.
    var showsSnakeControls = true

    // Seeded from the persisted values on appear rather than bound directly to them: the
    // stores are plain UserDefaults-backed statics, not observable, so a @State mirror is what
    // makes the switches move.
    @State private var soundOn = !GameAudio.isMuted
    @State private var hapticsOn = !GameHaptics.isDisabled
    @State private var control = SnakeChoiceStore.controlScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: VoiidSpacing.lg) {
                    VoiidCardSection(
                        footer: "Games play at your media volume, even on silent. They never play over a call."
                    ) {
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

                        VoiidRowDivider(inset: 52)

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
                    }

                    // SNAKE ONLY, and labelled as such. Sound and haptics above apply to every
                    // game; a control scheme applies to exactly one, and burying that distinction
                    // would have players hunting for why the setting did nothing in cricket.
                    if showsSnakeControls {
                    VoiidCardSection(
                        "Snake",
                        footer: "Applies right away."
                    ) {
                        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                            Text("Steering")
                                .font(VoiidFont.rounded(16, .semibold))
                                .foregroundStyle(VoiidColor.textPrimary)

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
                        }
                        .padding(VoiidSpacing.md)
                    }
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.sm)
                .padding(.bottom, VoiidSpacing.xl)
            }
            .scrollIndicators(.hidden)
            .softScrollEdge([.top, .bottom])
            .softTopEdgeEffect()
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Game settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onClose() }
                        .fontWeight(.semibold)
                        .foregroundStyle(VoiidColor.primary)
                }
            }
        }
        .softTopEdgeEffect()
        .softScrollEdge([.top, .bottom])
        .tint(VoiidColor.primary)
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
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 12)
    }
}

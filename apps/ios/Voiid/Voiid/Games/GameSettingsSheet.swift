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
//  DELIBERATELY TWO SWITCHES AND NOTHING ELSE. §12 also lists a Snake control scheme, a
//  left/right-handed layout and a graphics-quality tier; those are real settings for real
//  problems, and none of them is what shipping realistic audio just made necessary.
//
//  Mirrors Android `GameSettingsSheet.kt`.
//

import SwiftUI

struct GameSettingsSheet: View {
    var onClose: () -> Void

    // Seeded from the persisted values on appear rather than bound directly to them: the
    // stores are plain UserDefaults-backed statics, not observable, so a @State mirror is what
    // makes the switches move.
    @State private var soundOn = !GameAudio.isMuted
    @State private var hapticsOn = !GameHaptics.isDisabled

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
                    Text("Games always respect the silent switch and never play over a call.")
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

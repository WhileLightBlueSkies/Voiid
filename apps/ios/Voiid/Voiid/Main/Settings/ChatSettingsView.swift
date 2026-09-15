//
//  ChatSettingsView.swift
//  Voiid
//
//  Settings → Chats. The two chat preferences that ACTUALLY WORK, on the screen whose
//  name promises them.
//
//  ── WHY THIS FILE EXISTS ────────────────────────────────────────────────────────
//  The sheet had a "Chats — Theme, wallpaper, chat settings" row pointing at an UNWIRED
//  preview screen, while the two real chat preferences (chat-list layout and appearance)
//  sat in a separate "Display" group on the settings root. So the row that said "Chats"
//  did nothing, and the settings that did something were filed under a heading nobody
//  looks under for them.
//
//  Both preferences are genuinely chat settings: `ChatLayoutPreference` changes how the
//  chat LIST renders, and the appearance mode is the theme those chats are drawn in.
//  Neither belongs to a generic "Display" bucket that contained nothing else.
//
//  ── WHAT IS NOT HERE, AND WHY ───────────────────────────────────────────────────
//  Wallpaper, font size, "enter is send" and media auto-download were listed on the old
//  preview screen as inert rows. None of them has an implementation anywhere in the app,
//  so they are ABSENT rather than shown disabled — the same rule the settings root already
//  follows for features that do not exist. A control that cannot work should not take up
//  a row that implies it can.
//
//  The row subtitle changed with this screen ("Theme, wallpaper, chat settings" →
//  "Chat list layout, appearance"): it now names what is actually behind it.
//
//  ── INLINE PICKERS, NOT PUSHED SCREENS ──────────────────────────────────────────
//  Both results are visible the moment you tap. Navigating away to choose and back to see
//  the effect would be strictly worse, which is why these were inline on the root and stay
//  inline here.
//

import SwiftUI

@MainActor
struct ChatSettingsView: View {
    @ObservedObject private var chatLayout = ChatLayoutPreference.shared
    @ObservedObject private var theme = ThemePreference.shared

    var body: some View {
        ScrollView {
            VStack(spacing: VoiidSpacing.md) {
                VoiidCardSection(
                    "Chat list",
                    footer: "How conversations are laid out on the Chats tab."
                ) {
                    Picker("Chat list", selection: Binding(
                        get: { chatLayout.layout },
                        set: { Haptics.selection(); chatLayout.layout = $0 }
                    )) {
                        ForEach(ChatLayoutPreference.Layout.allCases) { l in
                            Text(l.label).tag(l)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, VoiidSpacing.sm)
                }

                VoiidCardSection(
                    "Appearance",
                    footer: "Applies to the whole app. System follows your device setting."
                ) {
                    Picker("Appearance", selection: Binding(
                        get: { theme.mode },
                        set: { Haptics.selection(); theme.mode = $0 }
                    )) {
                        ForEach(ThemePreference.Mode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, VoiidSpacing.sm)
                }
            }
            .padding(VoiidSpacing.md)
        }
        .softTopEdgeEffect()
        .scrollIndicators(.hidden)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
    }
}

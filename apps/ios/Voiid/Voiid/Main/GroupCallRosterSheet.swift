//
//  GroupCallRosterSheet.swift
//  Voiid
//
//  The participant roster for a group call (plan item 3.15, part 2).
//
//  ── WHY THE GRID IS NOT ENOUGH ───────────────────────────────────────────────────
//  The call grid answers "what does the call look like". It does not answer "who is here" —
//  past a handful of people the tiles are too small to read a name off, mute state is a
//  corner badge a few points across, and someone with their camera off is a monogram. On a
//  1000-member group the call may hold dozens of people and the grid becomes unreadable
//  exactly when knowing the roster matters most.
//
//  ── THIS IS A VIEW, NOT A CONTROL PANEL ──────────────────────────────────────────
//  There are deliberately no moderation affordances here — no remote mute, no remove. Muting
//  someone else's microphone from your device is a capability this app does not have and
//  should not grow casually: it needs a permission model (who may do it, to whom) that the
//  group-roles work defines but the CALL layer does not yet consult. Shipping the button
//  before the model exists is how you get a call where anyone can silence anyone.
//
//  Nothing here is derived from server state. Every row comes from the live LiveKit session
//  the device is already in, so the roster cannot disagree with the call it describes.
//

import SwiftUI

struct GroupCallRosterSheet: View {
    let participants: [GroupCallParticipant]

    @Environment(\.dismiss) private var dismiss

    /// Speakers first, then everyone else alphabetically, with YOU pinned to the top.
    ///
    /// Sorting by speaking state alone would make the list jump every time somebody drew
    /// breath, so the ordering is stable within each bucket — a name only moves when the
    /// person actually starts or stops talking, never on a re-render.
    private var ordered: [GroupCallParticipant] {
        participants.sorted { a, b in
            if a.isLocal != b.isLocal { return a.isLocal }
            if a.isSpeaking != b.isSpeaking { return a.isSpeaking }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            // Lazy: a group call roster is bounded by who JOINED, but that is not a number
            // this screen gets to assume — 1000-member groups are a supported shape.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ordered) { p in
                        row(p)
                        Divider().overlay(VoiidColor.textSecondary.opacity(0.15))
                    }
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("On this call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ p: GroupCallParticipant) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            ZStack {
                Circle()
                    .fill(VoiidColor.surfaceCard)
                    .frame(width: 40, height: 40)
                Text(initials(p.displayName))
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            // The same accent ring the grid tile uses, so "who is talking" reads identically
            // in both places rather than being two different visual languages.
            .overlay(
                Circle().stroke(VoiidColor.accent, lineWidth: p.isSpeaking ? 2.5 : 0)
            )
            .animation(.easeOut(duration: 0.15), value: p.isSpeaking)

            VStack(alignment: .leading, spacing: 1) {
                Text(p.isLocal ? "\(p.displayName) (you)" : p.displayName)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                if p.isSpeaking {
                    Text("Speaking")
                        .font(VoiidFont.rounded(11, .regular))
                        .foregroundColor(VoiidColor.accent)
                }
            }

            Spacer(minLength: 0)

            // Muted is shown; UNmuted deliberately is not. A row of "everyone's mic is on"
            // icons is noise — the badge exists to flag the exception.
            if p.isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 13))
                    .foregroundColor(VoiidColor.textSecondary)
                    .accessibilityLabel("Microphone off")
            }
            Image(systemName: p.hasVideo ? "video.fill" : "video.slash.fill")
                .font(.system(size: 13))
                .foregroundColor(p.hasVideo ? VoiidColor.primary : VoiidColor.textSecondary)
                .accessibilityLabel(p.hasVideo ? "Camera on" : "Camera off")
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

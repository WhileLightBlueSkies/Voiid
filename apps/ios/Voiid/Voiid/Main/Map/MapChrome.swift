//
//  MapChrome.swift
//  Voiid
//
//  Owns: the two persistent strips of top chrome below the search field — the visibility pill
//  and the away / waiting strip.
//
//  Deliberately NOT here: the wording of the pill. `MapVisibilityPill.text(...)` is a pure
//  function of the two facts it needs, and the shell calls it once and gives the same string
//  to both this pill and the header — so the two can never disagree about whether you are
//  visible. Nor does this file decide WHICH strip is shown; the shell swaps the away strip for
//  the suggestion list so the top chrome never stacks into a wall.
//

import SwiftUI

// MARK: - Visibility pill (persistent, unmissable)

struct MapVisibilityPill: View {
    let isVisible: Bool
    let text: String
    let onTap: () -> Void

    /// The single wording of visibility state, shared with the header.
    static func text(isVisible: Bool, audienceCount: Int) -> String {
        if !isVisible { return "Ghost Mode — hidden from everyone" }
        let n = audienceCount
        return n == 1 ? "Visible to 1 person" : "Visible to \(n) people"
    }

    var body: some View {
        Button {
            Haptics.tap()
            onTap()
        } label: {
            HStack(spacing: VoiidSpacing.sm) {
                Circle()
                    .fill(isVisible ? VoiidColor.primary : VoiidColor.textSecondary)
                    .frame(width: 8, height: 8)
                    .opacity(isVisible ? 1 : 0.5)
                Text(text)
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundColor(isVisible ? VoiidColor.textOnPrimary : VoiidColor.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor((isVisible ? VoiidColor.textOnPrimary : VoiidColor.textSecondary).opacity(0.8))
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(isVisible ? VoiidColor.primary : VoiidColor.surfaceCard)
            )
            .overlay(
                Capsule().stroke(VoiidColor.fieldBorder.opacity(isVisible ? 0 : 1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Away / waiting strip (contacts off the map)
//
// Aged-out contacts keep their last-known position off the map but appear here with a
// "last seen" — that is the honest signal that a phone went dark, distinct from an
// explicit stop (which erases them entirely). Contacts who shared but haven't sent a
// first fix yet show "Locating…".

struct MapAwayStrip: View {
    /// Shared-but-not-yet-located contacts, as userIds.
    let waiting: [String]
    /// Contacts whose last fix has aged out.
    let away: [MapPresence]
    let displayName: (String) -> String
    let photoURL: (String) -> String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(waiting, id: \.self) { uid in
                    chip(name: displayName(uid), subtitle: "Locating…",
                         photo: photoURL(uid))
                }
                ForEach(away) { p in
                    chip(name: displayName(p.senderUserId),
                         subtitle: "Last seen \(MapFormatters.relativeAge(p.fixedAt))",
                         photo: photoURL(p.senderUserId))
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(name: String, subtitle: String, photo: String?) -> some View {
        HStack(spacing: 6) {
            ProfileAvatarButton(photoURL: photo, name: name, size: 26)
                .saturation(0.2)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(VoiidFont.rounded(12, .semibold)).foregroundColor(VoiidColor.textPrimary)
                Text(subtitle).font(VoiidFont.rounded(10, .regular)).foregroundColor(VoiidColor.textSecondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Capsule().fill(VoiidColor.surfaceCard))
        .overlay(Capsule().stroke(VoiidColor.fieldBorder, lineWidth: 1))
    }
}

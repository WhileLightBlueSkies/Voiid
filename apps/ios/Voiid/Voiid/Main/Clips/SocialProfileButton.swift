//
//  SocialProfileButton.swift
//  Voiid
//
//  Your own avatar, top-right, opening your Social Profile.
//
//  ── WHY IT IS SHARED ────────────────────────────────────────────────────────────
//  The Social Profile is ONE public identity across Clips, Games and Communities, and the
//  way to reach it should not be three different things in three places. Clips grew this
//  button first; Games and Communities had no way in at all, so the same identity was one
//  tap away on one tab and unreachable on the other two.
//
//  ── WHY IT CAN BE ABSENT ────────────────────────────────────────────────────────
//  It renders nothing until a profile exists. Before that there is no page to open, and a
//  button that raises the setup sheet from a tab header would be asking for an identity at
//  the moment somebody is trying to browse — the gate belongs on the public ACTION (posting,
//  joining, liking), not on arriving.
//

import SwiftUI

struct SocialProfileButton: View {
    @EnvironmentObject private var social: SocialEngine

    /// Where the profile should open. Each surface owns its own navigation, so the caller
    /// decides rather than this view pushing into a stack it cannot see.
    var onOpen: (String) -> Void

    /// 38pt visible inside a 44pt target, matching the Clips original.
    var diameter: CGFloat = 38

    var body: some View {
        if let me = social.me {
            Button {
                Haptics.tap()
                onOpen(me.handle)
            } label: {
                avatar(me)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    // The accent ring marks this one avatar as YOURS. Every other avatar on
                    // these surfaces is unringed, so the ring is the only thing telling "me"
                    // from "someone" at this size.
                    .overlay(Circle().stroke(VoiidColor.accent, lineWidth: 2).padding(-3))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SoftPressStyle())
            .accessibilityLabel("Your Social Profile, @\(me.handle)")
        }
    }

    @ViewBuilder
    private func avatar(_ p: SocialService.Profile) -> some View {
        if let url = p.avatar_url {
            // ClipThumbnail fills internally; a second scaledToFill leaves it unbounded.
            ClipThumbnail(url: url)
        } else {
            ZStack {
                Circle().fill(VoiidColor.fieldFill)
                Text(String(p.handle.prefix(1)).uppercased())
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
    }
}

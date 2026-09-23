//
//  CommunityBadges.swift
//  Voiid
//
//  The two marks Voiid grants from the admin panel (087), drawn the same way everywhere.
//
//  ── BOTH ARE THE SERVER'S CLAIM ─────────────────────────────────────────────────
//  A host cannot give either. `author_badge` and `institution_name` are written only by a
//  Voiid admin, so a reader can trust them the way they trust the official seal — which is
//  exactly why neither is drawn from anything the user typed.
//
//  ── MODULAR BY DESIGN ───────────────────────────────────────────────────────────
//  `author_badge` is a word from a vocabulary the server may grow. This build draws the words
//  it knows and NOTHING for one it does not: an unlabelled pill would be a claim with no
//  content, and a guessed label could be wrong.
//

import SwiftUI

/// "Community moderator" beside an author's name on a post.
struct CommunityAuthorTag: View {
    let badge: String?

    private var label: String? {
        switch badge {
        case "community_moderator": "Community moderator"
        default: nil
        }
    }

    var body: some View {
        if let label {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(label)
                    .font(VoiidFont.rounded(10.5, .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(VoiidColor.accentInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(VoiidColor.accentTint))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label), verified by Voiid")
        }
    }
}

/// The verified-institution line under a community's name: "✓ Northstar University".
struct InstitutionMark: View {
    let name: String?
    var compact = false

    var body: some View {
        if let name, !name.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                Text(name)
                    .font(VoiidFont.rounded(compact ? 11.5 : 12.5, .semibold))
                    .lineLimit(1)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
            }
            .foregroundColor(VoiidColor.accentInk)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Verified institution: \(name)")
        }
    }
}

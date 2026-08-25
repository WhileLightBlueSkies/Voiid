//
//  MapHeader.swift
//  Voiid
//
//  Owns: the header row — my avatar, the "Map" title, the always-visible visibility status
//  line, and the Ghost Mode toggle in the right-hand slot.
//
//  Who I am, where I am, and — the question this screen exists to answer — whether anyone
//  can currently see me. The status line reuses `pillText` verbatim rather than deriving a
//  second wording of the same state, so the header and the pill can never disagree. That is
//  why the wording arrives as a parameter here: one string, computed once by the shell, used
//  by both the header and the pill.
//
//  The reference's right-hand slot is a notifications bell with a hard-coded badge count.
//  Voiid has no notification centre and nothing to count, so that slot carries the real
//  control this screen already owns instead: Ghost Mode, the same action (and the same
//  eye / eye.slash iconography) as the toolbar button, within thumb reach of the map.
//
//  Deliberately NOT here: the ghost action itself. The toggle reports the tap; whether that
//  opens the duration dialog or leaves ghost is the shell's rule, held in ONE place so the
//  toolbar button and this button can never diverge.
//

import SwiftUI

struct MapHeader: View {
    let photoURL: String?
    let fullName: String
    let isVisible: Bool
    /// The pill's wording, verbatim — see the note above on why this is passed in.
    let statusText: String
    let onToggleGhost: () -> Void

    var body: some View {
        HStack(spacing: VoiidSpacing.sm) {
            ProfileAvatarButton(photoURL: photoURL,
                                name: fullName,
                                size: 38)
                .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2))

            Spacer(minLength: 0)

            VStack(spacing: 1) {
                Text("Map")
                    .font(VoiidFont.rounded(17, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)

                // The always-visible answer to "can anyone see me?".
                HStack(spacing: 4) {
                    Image(systemName: isVisible ? "dot.radiowaves.left.and.right"
                                                : "eye.slash.fill")
                        .font(.system(size: 9))
                    Text(statusText)
                        .font(VoiidFont.rounded(11))
                        .lineLimit(1)
                }
                .foregroundColor(isVisible ? VoiidColor.accentInk
                                           : VoiidColor.textSecondary)
            }

            Spacer(minLength: 0)

            Button {
                Haptics.tap()
                onToggleGhost()
            } label: {
                Image(systemName: isVisible ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isVisible ? VoiidColor.accentInk
                                               : VoiidColor.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(VoiidColor.surfaceCard))
                    .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible ? "You are visible on the Map"
                                          : "Ghost Mode is on")
        }
    }
}

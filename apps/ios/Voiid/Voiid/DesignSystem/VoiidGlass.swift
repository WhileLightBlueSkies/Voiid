//
//  VoiidGlass.swift
//  Voiid
//
//  Apple's Liquid Glass MATERIAL (iOS 26 `.glassEffect`) on a Capsule/Circle, with a flat
//  fallback on iOS 18–25 where Liquid Glass does not exist. Used for the chat-screen header
//  pill — a single continuous pill spanning avatar → name → call → video → ⋯ — which the
//  native toolbar cannot express (it splits `.principal` from `.topBarTrailing`). The
//  material is Apple's own, so it is native glass, not a hand-rolled fill.
//

import SwiftUI

extension View {
    /// Capsule-shaped Liquid Glass (iOS 26) / flat surface (older).
    @ViewBuilder
    func voiidGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: Capsule())
        } else {
            self
                .background(VoiidColor.surfaceCard, in: Capsule())
                .overlay(Capsule().stroke(VoiidColor.textSecondary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }

    /// Circle-shaped Liquid Glass (iOS 26) / flat surface (older). For the round back button.
    @ViewBuilder
    func voiidGlassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: Circle())
        } else {
            self
                .background(VoiidColor.surfaceCard, in: Circle())
                .overlay(Circle().stroke(VoiidColor.textSecondary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }
}

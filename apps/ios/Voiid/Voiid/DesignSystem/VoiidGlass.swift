//
//  VoiidGlass.swift
//  Voiid
//
//  Apple's Liquid Glass on iOS 26, with a graceful flat fallback on iOS 18–25 (where
//  Liquid Glass does not exist). Using `.glassEffect` means the header pill is the REAL
//  system material — not a hand-rolled fill that "looks custom" — while still rendering
//  cleanly on older OS versions.
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

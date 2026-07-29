//
//  LocationAccuracy.swift
//  Voiid
//
//  "Accurate to about N m" — the ONE place this sentence is produced, so the chat bubble, the
//  full-screen detail and the Map contact card cannot drift apart. Android's mirror lives in
//  `LocationDetailView.kt` (`accuracyNote`).
//
//  WHY IT EXISTS: a marker drawn as a single point reads as an exact doorstep, and it is not.
//  A phone fix is typically 10–30 m in the open and considerably worse indoors or between tall
//  buildings, so someone navigating to a friend needs to know the pin carries a radius.
//
//  We show the accuracy the SENDER'S DEVICE actually reported for that fix rather than a fixed
//  marketing number — inventing a figure would be its own dishonesty. `fallbackAccuracyMetres`
//  covers only the case where a payload carried no accuracy at all.
//
//  NOTE the two features differ, and this must not paper over it: conversation live share (A)
//  carries the real device accuracy, while Map presence (B) deliberately COARSENS accuracy to
//  ≥100 m before it is ever sent (see `MapEnvelope.fix`, docs/LOCATION.md §5). Feeding each
//  surface its own value means the Map honestly reads "about 100 m" instead of borrowing the
//  chat's tighter number.
//
//  This is separate from the coordinate rounding we apply (5 dp ≈ 1 m), which is a privacy
//  measure far finer than the fix's own error and so never dominates this figure.
//

import Foundation

enum LocationAccuracy {
    /// Used only when a payload carried no accuracy at all — a conservative typical GPS fix.
    static let fallbackAccuracyMetres = 30

    /// The user-facing sentence. Pass the accuracy from the fix being drawn, or nil.
    static func note(_ accuracy: Double?) -> String {
        let metres = Int(accuracy.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Double(fallbackAccuracyMetres))
        return "Accurate to about \(rounded(metres)) m — GPS is approximate"
    }

    /// Round to something that reads as an estimate, never a false precision like "37 m".
    private static func rounded(_ metres: Int) -> Int {
        switch metres {
        case ..<11:   return 10
        case ..<31:   return ((metres + 4) / 5) * 5
        case ..<101:  return ((metres + 9) / 10) * 10
        default:      return ((metres + 49) / 50) * 50
        }
    }
}

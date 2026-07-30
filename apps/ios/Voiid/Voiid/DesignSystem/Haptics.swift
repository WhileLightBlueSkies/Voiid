//
//  Haptics.swift
//  Voiid
//
//  Lightweight haptic feedback helpers for Apple-grade interaction feel.
//

import UIKit

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
    static func rigid() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A rising thump for a big moment — a six clearing the rope, a match won.
    ///
    /// WHY NOT JUST `rigid()`: one impact is over before the ball has left the screen, so the
    /// biggest event in the game would feel identical to pressing a button. Two impacts a beat
    /// apart, soft then hard, last about as long as the strike animation, which is what makes it
    /// read as impact rather than acknowledgement. Mirrors Android `VoiidHaptics.boundary()`.
    static func boundary() {
        let soft = UIImpactFeedbackGenerator(style: .soft)
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        // Prepared up front so the second impact isn't delayed by generator warm-up, which would
        // stretch the gap and break the crescendo.
        soft.prepare()
        heavy.prepare()
        soft.impactOccurred(intensity: 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            heavy.impactOccurred(intensity: 1.0)
        }
    }
}

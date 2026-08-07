//
//  GameHaptics.swift
//  Voiid
//
//  Core Haptics for in-match events (GAMES_ANIMATION.md §8), as opposed to `Haptics.swift`'s
//  UIKit feedback generators for ordinary UI taps.
//
//  WHY THIS IS A SEPARATE FILE FROM Haptics.swift. `UIImpactFeedbackGenerator` gives five
//  coarse presets and no control over envelope — right for "I tapped a button", wrong for "I
//  just killed another player's snake and I want the hit to feel weighty." Core Haptics lets a
//  haptic be AUTHORED alongside its sound and its visual with the same numbers: a kill's sharp
//  transient plus decaying rumble here uses the identical envelope shape as the kill sound's
//  recipe in docs/GAMES_AUDIO.md §8.6 and the hitstop/shake in SnakeMetalView's ImpactTimeline.
//  Three channels landing on one event is what makes it read as ONE beat instead of three.
//
//  Mirrors Android's tiered VibrationEffect approach in SnakeArenaScreen.kt — same event-to-
//  haptic mapping, necessarily different APIs (Core Haptics has no Android equivalent, and
//  Android's own haptic API is itself tiered by SDK level; see that file's comment for why).
//

import CoreHaptics

enum GameHaptics {
    /// Lazily created, and re-created if the hardware engine stops (background, reset). `nil`
    /// on devices with no Taptic Engine (some iPads) — every call below no-ops in that case
    /// rather than crashing, which is the same posture `Haptics.swift` takes implicitly via
    /// UIKit's generators being safe no-ops on unsupported hardware.
    private static var engine: CHHapticEngine?

    private static func ensureEngine() -> CHHapticEngine? {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        if let engine { return engine }
        guard let e = try? CHHapticEngine() else { return nil }
        e.stoppedHandler = { _ in engine = nil }        // rebuilt lazily on next call
        e.resetHandler = { try? engine?.start() }
        try? e.start()
        engine = e
        return e
    }

    private static func play(_ events: [CHHapticEvent]) {
        guard let engine = ensureEngine(),
              let pattern = try? CHHapticPattern(events: events, parameters: []),
              let player = try? engine.makePlayer(with: pattern) else { return }
        try? engine.start()
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    /// Light tick on eating. Flat intensity, deliberately: the `eat` server event carries no
    /// food value (only position and eater id — see snake/index.ts's `k: 'eat'` push), and
    /// this fires up to several times a second, so a per-pickup intensity distinction would be
    /// imperceptible anyway at this rate. `eatBig` exists in the AUDIO catalogue
    /// (docs/GAMES_AUDIO.md §8.2) for the corpse-food distinction; haptics stays uniform here.
    static func eat() {
        play([CHHapticEvent(eventType: .hapticTransient, parameters: [
            .init(parameterID: .hapticIntensity, value: 0.4),
            .init(parameterID: .hapticSharpness, value: 0.7),
        ], relativeTime: 0)])
    }

    /// Quick rise on boost engaging — a single ramped-intensity transient reads as "spooling
    /// up" rather than a flat tap.
    static func boostStart() {
        play([CHHapticEvent(eventType: .hapticContinuous, parameters: [
            .init(parameterID: .hapticIntensity, value: 0.5),
            .init(parameterID: .hapticSharpness, value: 0.8),
        ], relativeTime: 0, duration: 0.12)])
    }

    /// Sharp transient + a short decaying rumble. Same envelope shape as the `kill` sound
    /// recipe in docs/GAMES_AUDIO.md §8.6 (impact + descending tone + sub) and the 120ms
    /// hitstop in ImpactTimeline — three channels, one beat.
    static func kill() {
        play([
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                .init(parameterID: .hapticIntensity, value: 1.0),
                .init(parameterID: .hapticSharpness, value: 0.9),
            ], relativeTime: 0),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                .init(parameterID: .hapticIntensity, value: 0.55),
                .init(parameterID: .hapticSharpness, value: 0.2),
            ], relativeTime: 0.02, duration: 0.18),
        ])
    }

    /// Heavy transient + a longer decaying rumble — the biggest haptic in the game, matching
    /// death being the biggest audio/visual moment (docs/GAMES_AUDIO.md §8.7,
    /// ImpactTimeline's 100ms freeze + 500ms slow-mo).
    static func death() {
        play([
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                .init(parameterID: .hapticIntensity, value: 1.0),
                .init(parameterID: .hapticSharpness, value: 0.6),
            ], relativeTime: 0),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                .init(parameterID: .hapticIntensity, value: 0.7),
                .init(parameterID: .hapticSharpness, value: 0.15),
            ], relativeTime: 0.03, duration: 0.4),
        ])
    }

    /// Soft pulse for the arena border danger vignette — intensity scaled 0 (far) to 1
    /// (about to die). Deliberately gentle even at full intensity: this can retrigger every
    /// frame while a player hugs the wall, and a strong haptic on a loop reads as the device
    /// malfunctioning rather than as a warning.
    static func borderPulse(proximity: Float) {
        guard proximity > 0.05 else { return }
        play([CHHapticEvent(eventType: .hapticTransient, parameters: [
            .init(parameterID: .hapticIntensity, value: min(proximity * 0.4, 0.4)),
            .init(parameterID: .hapticSharpness, value: 0.1),
        ], relativeTime: 0)])
    }
}

//
//  MapVisibilityState.swift
//  Voiid
//
//  The persisted state behind your own presence on the Map. Modelled on
//  `PrivacySettings` — a `@MainActor ObservableObject` singleton whose published values
//  write through to namespaced `UserDefaults` keys on `didSet`.
//
//  THE SAFETY DEFAULT (§8): `mode` defaults to `.ghost`. You appear to NO ONE until you
//  name individuals. An absent key therefore reads as ghost, never visible — the exact
//  inverse of the `PrivacySettings` "absent = on" rule, because the safe default here is
//  OFF, not on.
//
//  Ghost is a HARD LOCAL GATE. Nothing in this app may take a location fix for the Map
//  while `isEffectivelyGhosted` is true. It is not "we filter server-side"; the fix is
//  never taken (§8). `MapPresenceEngine` is the sole reader that enforces this, and it
//  consults `isEffectivelyGhosted` before every emission.
//

import Foundation
import Combine

@MainActor
final class MapVisibilityState: ObservableObject {

    static let shared = MapVisibilityState()

    private enum Key {
        static let mode         = "voiid.map.visibility.mode"
        static let ghostUntil   = "voiid.map.ghost.until"        // Double (timeIntervalSince1970), 0 = untilOff
        static let lastForeground = "voiid.map.lastForegrounded" // Double — drives the 24h auto-ghost
    }

    /// Your standing state. `.ghost` unless you have explicitly chosen to be visible.
    @Published private(set) var mode: MapVisibilityMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Key.mode) }
    }

    /// When a TIMED ghost lifts (1 h / until tomorrow). nil means `.untilOff` — indefinite
    /// until the user turns it back on. Only meaningful while `mode == .ghost`.
    @Published private(set) var ghostUntil: Date? {
        didSet {
            UserDefaults.standard.set(ghostUntil?.timeIntervalSince1970 ?? 0, forKey: Key.ghostUntil)
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Key.mode),
           let m = MapVisibilityMode(rawValue: raw) {
            mode = m
        } else {
            mode = .ghost   // safe default — absent key is ghost, never visible
        }
        let until = UserDefaults.standard.double(forKey: Key.ghostUntil)
        ghostUntil = until > 0 ? Date(timeIntervalSince1970: until) : nil
    }

    // MARK: - Derived

    /// True whenever this device must NOT emit — either explicitly ghosted, or the 24-hour
    /// auto-ghost has fired (§3: no foreground in 24 h ⇒ stop emitting). This is the single
    /// predicate every emission path checks.
    var isEffectivelyGhosted: Bool {
        if mode == .ghost { return true }
        if autoGhostTripped { return true }
        return false
    }

    var isVisible: Bool { !isEffectivelyGhosted }

    /// The 24-hour hard auto-ghost. Visibility is never something you forget about for a
    /// week — if the app has not been foregrounded in 24 h the client stops emitting (§3).
    private var autoGhostTripped: Bool {
        let last = UserDefaults.standard.double(forKey: Key.lastForeground)
        guard last > 0 else { return false }
        return Date().timeIntervalSince1970 - last > 24 * 60 * 60
    }

    /// Record a foreground so the 24-hour auto-ghost clock resets. Called from the Map's
    /// `onAppear`/scene-active path.
    func noteForegrounded() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.lastForeground)
        // A timed ghost that has elapsed lifts on the next foreground.
        if mode == .ghost, let until = ghostUntil, until <= Date() {
            ghostUntil = nil
        }
        objectWillChange.send()
    }

    // MARK: - Transitions (state only — MapPresenceEngine performs the network + key work)

    /// Enter the visible state locally. The engine mints the key, distributes it, creates
    /// the server row and starts the coarse provider — this only flips the flag.
    func markVisible() {
        ghostUntil = nil
        mode = .visible
    }

    /// Enter Ghost Mode locally, optionally timed. `.untilOff` is the default the toggle
    /// uses. The engine still performs the emit-stop + key rotation + control fan-out.
    func markGhost(_ duration: GhostDuration = .untilOff) {
        ghostUntil = duration.expiry()
        mode = .ghost
    }
}

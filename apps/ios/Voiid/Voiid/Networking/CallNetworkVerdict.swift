//
//  CallNetworkVerdict.swift
//  Voiid
//
//  "Your network is weak" — whether THIS phone's connection is the weak one on a call.
//
//  Shown only to the person whose network it is. The other person sees nothing unless
//  theirs is weak too; a warning about someone else's connection is not something you
//  can act on.
//
//  ── WHOSE NETWORK? ─────────────────────────────────────────────────────────────────
//  Round-trip time is shared by both ends, so on its own it cannot say whose connection is
//  at fault. Direction can:
//    * UPLINK loss — media this phone sent that the other side never received, reported
//      back over RTCP — points at this phone.
//    * High round-trip time WITH some uplink loss is queueing on this phone's uplink: the
//      usual shape of a congested mobile or Wi-Fi connection sending more than it can.
//    * Loss in BOTH directions at once is most likely this phone's own connection.
//    * Loss only in the direction we RECEIVE is usually the other person's uplink. It is
//      left alone here; their phone raises it for them.
//    * High round-trip time with no loss either way cannot be attributed, so neither side
//      is told. Telling both would warn someone whose network is fine.
//
//  Pure — no WebRTC, no UI — so every case runs in checks/call-network (see its README).
//

import Foundation

enum CallNetworkVerdict {
    /// Is the weakness on this side, for one stats sample? Nil when there is nothing to judge
    /// yet (no round-trip time and no uplink report) — the caller keeps its current state.
    static func ownSideLooksWeak(uplinkLossPct: Double?, downlinkLossPct: Double?, rttMs: Double?) -> Bool? {
        guard uplinkLossPct != nil || rttMs != nil else { return nil }
        let up = uplinkLossPct ?? 0
        let down = downlinkLossPct ?? 0
        let rtt = rttMs ?? 0
        if up >= 8 { return true }
        if rtt >= 700 && up >= 2 { return true }
        if down >= 10 && up >= 5 { return true }
        return false
    }
}

/// Turns per-sample verdicts into a banner that does not flicker.
///
/// Shown after 2 weak samples in a row, hidden after 3 good ones — with samples every 3s,
/// about 6s to appear and 9s to clear. One lost burst must not flash a warning, and a call
/// that is recovering must not bounce between states while it settles.
struct WeakNetworkTracker {
    static let showAfter = 2
    static let hideAfter = 3

    private(set) var isWeak = false
    private var weakStreak = 0
    private var goodStreak = 0

    mutating func record(_ weak: Bool?) {
        guard let weak else { return }          // no reading: keep what we have
        if weak { weakStreak += 1; goodStreak = 0 } else { goodStreak += 1; weakStreak = 0 }
        if !isWeak, weakStreak >= Self.showAfter { isWeak = true }
        if isWeak, goodStreak >= Self.hideAfter { isWeak = false }
    }

    mutating func reset() { self = WeakNetworkTracker() }
}

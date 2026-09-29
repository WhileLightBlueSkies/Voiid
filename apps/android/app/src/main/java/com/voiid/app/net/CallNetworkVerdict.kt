package com.voiid.app.net

/**
 * "Your network is weak" — whether THIS phone's connection is the weak one on a call.
 * Port of iOS `CallNetworkVerdict.swift`; both apps must decide identically, and
 * `CallNetworkVerdictTest` runs the same cases as iOS `checks/call-network`.
 *
 * Shown only to the person whose network it is. Round-trip time is shared by both ends, so it
 * can't say whose connection is at fault by itself; direction can:
 *  - UPLINK loss (media this phone sent that the other side never received, reported back
 *    over RTCP) points at this phone;
 *  - high round-trip time WITH some uplink loss is queueing on this phone's uplink;
 *  - loss in BOTH directions at once is most likely this phone's own connection;
 *  - loss only in the direction we RECEIVE is usually the other person's — their phone warns them;
 *  - high round-trip time with no loss either way can't be attributed, so nobody is told.
 */
object CallNetworkVerdict {
    /** Null when there is nothing to judge yet — the caller keeps its current state. */
    fun ownSideLooksWeak(uplinkLossPct: Double?, downlinkLossPct: Double?, rttMs: Double?): Boolean? {
        if (uplinkLossPct == null && rttMs == null) return null
        val up = uplinkLossPct ?: 0.0
        val down = downlinkLossPct ?: 0.0
        val rtt = rttMs ?: 0.0
        if (up >= 8.0) return true
        if (rtt >= 700.0 && up >= 2.0) return true
        if (down >= 10.0 && up >= 5.0) return true
        return false
    }
}

/**
 * Turns per-sample verdicts into a banner that doesn't flicker: shown after 2 weak samples in
 * a row, hidden after 3 good ones. One lost burst must not flash a warning, and a recovering
 * call must not bounce between states while it settles. Same as iOS `WeakNetworkTracker`.
 */
class WeakNetworkTracker {
    companion object { const val SHOW_AFTER = 2; const val HIDE_AFTER = 3 }

    var isWeak = false
        private set
    private var weakStreak = 0
    private var goodStreak = 0

    fun record(weak: Boolean?) {
        if (weak == null) return                 // no reading: keep what we have
        if (weak) { weakStreak++; goodStreak = 0 } else { goodStreak++; weakStreak = 0 }
        if (!isWeak && weakStreak >= SHOW_AFTER) isWeak = true
        if (isWeak && goodStreak >= HIDE_AFTER) isWeak = false
    }

    fun reset() { isWeak = false; weakStreak = 0; goodStreak = 0 }
}

package com.voiid.app

import com.voiid.app.net.CallNetworkVerdict
import com.voiid.app.net.WeakNetworkTracker
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Every case behind "Your network is weak" — the same cases, in the same order, as iOS
 * apps/ios/checks/call-network/main.swift. If one platform's answer changes, the two apps
 * start telling different people their network is weak.
 */
class CallNetworkVerdictTest {
    private fun weak(up: Double?, down: Double?, rtt: Double?) = CallNetworkVerdict.ownSideLooksWeak(up, down, rtt)

    @Test fun whoseNetworkIsWeak() {
        assertEquals("clean call", false, weak(0.0, 0.0, 40.0))
        assertEquals("my sent audio lost 12%", true, weak(12.0, 0.0, 90.0))
        assertEquals("only their audio lost reaching me", false, weak(0.0, 20.0, 90.0))
        assertEquals("900ms + my audio lost", true, weak(3.0, 0.0, 900.0))
        assertEquals("900ms, no loss: can't tell whose", false, weak(0.0, 0.0, 900.0))
        assertEquals("loss both ways", true, weak(6.0, 15.0, 200.0))
        assertEquals("just under uplink threshold", false, weak(7.9, 0.0, 100.0))
        assertEquals("exactly at uplink threshold", true, weak(8.0, 0.0, 100.0))
        assertEquals("no reading yet", null, weak(null, null, null))
        assertEquals("downlink only, nothing else yet", null, weak(null, 30.0, null))
        assertEquals("RTT but no uplink report yet", false, weak(null, 0.0, 60.0))
    }

    @Test fun todaysRealCalls() {
        assertEquals("3s round trip, 10% loss", true, weak(10.1, 10.1, 3082.0))
        assertEquals("567ms, 58% loss", true, weak(58.0, 58.0, 567.0))
        assertEquals("131ms, 1.8% loss — OK call", false, weak(1.8, 1.8, 131.0))
        assertEquals("last night's 16ms calls", false, weak(0.0, 0.0, 16.0))
    }

    @Test fun noFlicker() {
        val t = WeakNetworkTracker()
        t.record(true); assertEquals("one blip stays hidden", false, t.isWeak)
        t.record(false); t.record(true); assertEquals("weak,good,weak stays hidden", false, t.isWeak)
        t.record(true); assertEquals("2 weak in a row shows", true, t.isWeak)
        t.record(false); t.record(false); assertEquals("2 good: still shown", true, t.isWeak)
        t.record(true); assertEquals("weak mid-recovery restarts count", true, t.isWeak)
        t.record(false); t.record(false); t.record(false); assertEquals("3 good hides", false, t.isWeak)
        t.record(null); t.record(null); assertEquals("no readings: unchanged", false, t.isWeak)
        t.record(true); t.record(true); t.record(null); assertEquals("no reading while shown: stays", true, t.isWeak)
        t.reset(); assertEquals("new call resets", false, t.isWeak)
    }
}

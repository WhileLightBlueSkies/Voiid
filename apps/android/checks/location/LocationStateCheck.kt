package com.voiid.app.model

import kotlinx.serialization.json.Json

/** JVM checks of the real location wire models; no emulator or APK needed. */
fun main() {
    var checks = 0
    fun verify(value: Boolean) { check(value); checks++ }
    val now = 1_800_000_000_000L
    val waiting = LiveShareView("share", "owner", now + 900_000, 15, null, false)
    verify(waiting.state(now) == ShareState.STALE)
    verify(waiting.copy(endedExplicit = true).state(now) == ShareState.ENDED)
    verify(waiting.copy(expiresAt = now).state(now) == ShareState.ENDED)
    verify(waiting.copy(expiresAt = now - 1).state(now) == ShareState.ENDED)
    val stopped = waiting.copy(endedExplicit = true, stoppedBeforeExpiry = true)
    verify(stopped.state(now + 900_001) == ShareState.ENDED && stopped.stoppedBeforeExpiry)
    verify(!waiting.copy(endedExplicit = true).stoppedBeforeExpiry)
    val fix = LocationFix("share", "owner", 12.0, 77.0, 10.0, now, now)
    val live = waiting.copy(lastFix = fix)
    verify(live.state(now) == ShareState.LIVE)
    verify(live.state(now + 60_000) == ShareState.LIVE)
    verify(live.state(now + 60_001) == ShareState.STALE)
    verify(live.copy(endedExplicit = true).state(now) == ShareState.ENDED)
    verify(live.state(now + 900_000) == ShareState.ENDED)
    val json = Json { ignoreUnknownKeys = true }
    val iosStart = json.decodeFromString(LocationEnvelope.serializer(),
        """{"_vloc":1,"k":"live_start","s":"share","t":1800000000000.25,"expiresAt":1800000900000.25,"key":"key","cadence":15}""")
    verify(iosStart.lat == null && iosStart.lon == null)
    verify(iosStart.t == now && iosStart.expiresAt == now + 900_000)
    val iosFix = json.decodeFromString(LocationEnvelope.serializer(),
        """{"_vloc":1,"k":"fix","s":"share","n":1800000000000.25,"t":1800000000000,"lat":12,"lon":77,"acc":10}""")
    verify(iosFix.n == now)
    val encoded = json.encodeToString(LocationEnvelope.serializer(), iosFix)
    verify(json.decodeFromString(LocationEnvelope.serializer(), encoded) == iosFix)
    verify(!encoded.contains("1800000000000.0"))
    println("$checks location state and iOS wire-compatibility checks passed.")
}

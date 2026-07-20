package com.voiid.app.net

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import org.webrtc.PeerConnection
import org.webrtc.RTCStats
import org.webrtc.RTCStatsReport
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Coarse connection health, derived from packet loss + round-trip time. */
enum class CallQuality { UNKNOWN, GOOD, FAIR, POOR }

/**
 * A single point-in-time read of the live call, for a weak-connection indicator or debugging.
 * Every field is a measurement — nothing here identifies a person, a network, or an address.
 */
data class CallStatsSnapshot(
    val quality: CallQuality = CallQuality.UNKNOWN,
    val rttMs: Double? = null,
    val packetLossPct: Double = 0.0,
    val jitterMs: Double = 0.0,
    val inboundKbps: Double = 0.0,
    val outboundKbps: Double = 0.0,
    val framesDecoded: Long = 0,
    val freezeCount: Long = 0,
    val audioLevel: Double = 0.0,
    /** "host" / "srflx" / "prflx" / "relay" — the local end of the selected candidate pair. */
    val candidatePairType: String? = null,
    val relayed: Boolean = false,
)

/**
 * Samples `PeerConnection.getStats` on a timer while a call is up, exposes a live quality
 * signal, and accumulates the per-call aggregate that gets POSTed on hangup.
 *
 * Two hard rules govern everything in here:
 *
 * 1. **Telemetry never touches the call.** Every read is wrapped, the timer thread is separate
 *    from the media path, and any failure is swallowed. A stats bug must not be able to drop
 *    a working call.
 * 2. **Measurements only.** The uploaded aggregate carries counters and timings. It must never
 *    carry message content, SDP, ICE candidates, IP addresses, peer identity, or display names.
 *    See [buildMetricsBody] — that function is the entire surface that leaves the device.
 */
class CallMetricsCollector(
    private val context: Context,
    /** The CallManager executor — all PeerConnection access stays serialized onto it. */
    private val pcExecutor: Executor,
) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val timer = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "voiid-call-stats").apply { isDaemon = true }
    }
    private var task: ScheduledFuture<*>? = null
    private val reported = AtomicBoolean(false)

    private val _snapshot = MutableStateFlow(CallStatsSnapshot())
    val snapshot: StateFlow<CallStatsSnapshot> = _snapshot.asStateFlow()

    // ---- per-call accumulators -------------------------------------------------

    private val startedAtMs = System.currentTimeMillis()
    private var connectedAtMs: Long? = null

    private var rttSum = 0.0
    private var rttSamples = 0
    private var jitterSum = 0.0
    private var jitterSamples = 0
    private var lossPctSum = 0.0
    private var lossSamples = 0
    private var everRelayed = false

    /** Bumped by CallManager each time it kicks an ICE restart. */
    @Volatile var iceRestarts = 0

    // Deltas for bitrate.
    private var lastBytesIn = 0L
    private var lastBytesOut = 0L
    private var lastSampleAtMs = 0L
    // Cumulative RTP counters, for a whole-call loss percentage.
    private var lastPacketsLost = 0L
    private var lastPacketsReceived = 0L

    fun onConnected() {
        if (connectedAtMs == null) connectedAtMs = System.currentTimeMillis()
    }

    /** Begin sampling. Safe to call more than once. */
    fun start(pcProvider: () -> PeerConnection?) {
        if (task != null) return
        task = runCatching {
            timer.scheduleWithFixedDelay(
                { runCatching { sampleOnce(pcProvider) } },
                SAMPLE_INTERVAL_MS,
                SAMPLE_INTERVAL_MS,
                TimeUnit.MILLISECONDS,
            )
        }.getOrNull()
    }

    fun stop() {
        runCatching { task?.cancel(false) }
        task = null
        runCatching { timer.shutdownNow() }
    }

    private fun sampleOnce(pcProvider: () -> PeerConnection?) {
        pcExecutor.execute {
            runCatching {
                val pc = pcProvider() ?: return@execute
                pc.getStats { report -> runCatching { ingest(report) } }
            }
        }
    }

    // ---- report parsing --------------------------------------------------------

    private fun ingest(report: RTCStatsReport) {
        val stats = report.statsMap.values

        var packetsLost = 0L
        var packetsReceived = 0L
        var jitter = 0.0
        var jitterCount = 0
        var bytesIn = 0L
        var bytesOut = 0L
        var framesDecoded = 0L
        var freezeCount = 0L
        var audioLevel = 0.0
        var rtt: Double? = null

        for (s in stats) {
            when (s.type) {
                "inbound-rtp" -> {
                    packetsLost += num(s, "packetsLost")?.toLong() ?: 0L
                    packetsReceived += num(s, "packetsReceived")?.toLong() ?: 0L
                    bytesIn += num(s, "bytesReceived")?.toLong() ?: 0L
                    num(s, "jitter")?.let { jitter += it; jitterCount++ }
                    framesDecoded += num(s, "framesDecoded")?.toLong() ?: 0L
                    freezeCount += num(s, "freezeCount")?.toLong() ?: 0L
                    num(s, "audioLevel")?.let { if (it > audioLevel) audioLevel = it }
                }
                "outbound-rtp" -> bytesOut += num(s, "bytesSent")?.toLong() ?: 0L
                "remote-inbound-rtp" -> {
                    // The peer's view of our stream: the most trustworthy RTT we get.
                    num(s, "roundTripTime")?.let { rtt = it * 1000.0 }
                }
                "media-source" -> num(s, "audioLevel")?.let { if (it > audioLevel) audioLevel = it }
            }
        }

        // Selected candidate pair -> are we relayed through TURN, and what RTT does ICE see?
        val selected = stats.firstOrNull { s ->
            s.type == "candidate-pair" &&
                (bool(s, "selected") == true ||
                    (bool(s, "nominated") == true && str(s, "state") == "succeeded"))
        }
        var pairType: String? = null
        if (selected != null) {
            if (rtt == null) num(selected, "currentRoundTripTime")?.let { rtt = it * 1000.0 }
            val localId = str(selected, "localCandidateId")
            val remoteId = str(selected, "remoteCandidateId")
            val localType = localId?.let { str(report.statsMap[it], "candidateType") }
            val remoteType = remoteId?.let { str(report.statsMap[it], "candidateType") }
            pairType = localType
            if (localType == "relay" || remoteType == "relay") everRelayed = true
        }

        // Whole-call loss percentage from the cumulative counters' delta.
        val dLost = (packetsLost - lastPacketsLost).coerceAtLeast(0L)
        val dRecv = (packetsReceived - lastPacketsReceived).coerceAtLeast(0L)
        lastPacketsLost = packetsLost
        lastPacketsReceived = packetsReceived
        val lossPct = if (dLost + dRecv > 0) (dLost.toDouble() / (dLost + dRecv)) * 100.0 else 0.0

        val now = System.currentTimeMillis()
        val elapsedSec = if (lastSampleAtMs == 0L) 0.0 else (now - lastSampleAtMs) / 1000.0
        val inKbps = if (elapsedSec > 0) ((bytesIn - lastBytesIn).coerceAtLeast(0L) * 8.0) / elapsedSec / 1000.0 else 0.0
        val outKbps = if (elapsedSec > 0) ((bytesOut - lastBytesOut).coerceAtLeast(0L) * 8.0) / elapsedSec / 1000.0 else 0.0
        lastBytesIn = bytesIn
        lastBytesOut = bytesOut
        lastSampleAtMs = now

        val jitterMs = if (jitterCount > 0) (jitter / jitterCount) * 1000.0 else 0.0

        rtt?.let { rttSum += it; rttSamples++ }
        if (jitterCount > 0) { jitterSum += jitterMs; jitterSamples++ }
        if (dLost + dRecv > 0) { lossPctSum += lossPct; lossSamples++ }

        _snapshot.value = CallStatsSnapshot(
            quality = classify(lossPct, rtt),
            rttMs = rtt,
            packetLossPct = lossPct,
            jitterMs = jitterMs,
            inboundKbps = inKbps,
            outboundKbps = outKbps,
            framesDecoded = framesDecoded,
            freezeCount = freezeCount,
            audioLevel = audioLevel,
            candidatePairType = pairType,
            relayed = everRelayed,
        )
    }

    /**
     * Loss and latency thresholds tuned for speech: Opus with in-band FEC stays intelligible
     * to roughly 5% loss, and one-way delay becomes conversationally awkward past ~200 ms
     * (≈400 ms round trip).
     */
    private fun classify(lossPct: Double, rttMs: Double?): CallQuality {
        val r = rttMs ?: 0.0
        return when {
            lossPct >= 5.0 || r >= 400.0 -> CallQuality.POOR
            lossPct >= 2.0 || r >= 250.0 -> CallQuality.FAIR
            else -> CallQuality.GOOD
        }
    }

    // ---- upload ----------------------------------------------------------------

    /**
     * POST the anonymous per-call aggregate. Fire-and-forget on an IO thread; a 404 (endpoint
     * not deployed yet) or any other error is swallowed silently. Only ever runs once.
     */
    fun report(callId: String, connected: Boolean, endReason: String) {
        if (!reported.compareAndSet(false, true)) return
        val body = buildMetricsBody(callId, connected, endReason)
        scope.launch {
            runCatching { ApiClient(TokenStore.get(context)).request("POST", "calls/metrics", jsonBody = body) }
        }
    }

    /**
     * The complete set of bytes this feature sends off-device. Counters and timings only —
     * deliberately no SDP, no candidates, no addresses, no user ids, no display names.
     * `call_id` is an opaque per-call UUID, not a user identifier.
     */
    private fun buildMetricsBody(callId: String, connected: Boolean, endReason: String): String {
        val now = System.currentTimeMillis()
        val setupMs = connectedAtMs?.let { it - startedAtMs } ?: (now - startedAtMs)
        val durationMs = connectedAtMs?.let { now - it } ?: 0L
        val avgRtt = if (rttSamples > 0) rttSum / rttSamples else 0.0
        val avgLoss = if (lossSamples > 0) lossPctSum / lossSamples else 0.0
        val avgJitter = if (jitterSamples > 0) jitterSum / jitterSamples else 0.0
        return buildString {
            append("{\"call_id\":").append(JsonPrimitive(callId))
            append(",\"connected\":").append(connected)
            append(",\"setup_ms\":").append(setupMs)
            append(",\"duration_ms\":").append(durationMs)
            append(",\"end_reason\":").append(JsonPrimitive(endReason))
            append(",\"relayed\":").append(everRelayed)
            append(",\"ice_restarts\":").append(iceRestarts)
            append(",\"avg_rtt_ms\":").append(round1(avgRtt))
            append(",\"avg_packet_loss_pct\":").append(round1(avgLoss))
            append(",\"jitter_ms\":").append(round1(avgJitter))
            append(",\"platform\":\"android\"")
            append("}")
        }
    }

    private fun round1(v: Double): Double =
        if (v.isFinite()) Math.round(v * 10.0) / 10.0 else 0.0

    // ---- RTCStats member accessors (values arrive boxed and loosely typed) ------

    private fun num(s: RTCStats?, key: String): Double? = when (val v = s?.members?.get(key)) {
        is Number -> v.toDouble().takeIf { it.isFinite() }
        is String -> v.toDoubleOrNull()
        else -> null
    }

    private fun str(s: RTCStats?, key: String): String? = s?.members?.get(key) as? String

    private fun bool(s: RTCStats?, key: String): Boolean? = when (val v = s?.members?.get(key)) {
        is Boolean -> v
        is String -> v.toBooleanStrictOrNull()
        else -> null
    }

    private companion object {
        const val SAMPLE_INTERVAL_MS = 3_000L
    }
}

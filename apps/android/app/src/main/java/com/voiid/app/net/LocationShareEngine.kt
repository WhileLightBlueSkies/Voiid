package com.voiid.app.net

import android.content.Context
import android.location.Location
import android.util.Base64
import android.util.Log
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import com.voiid.app.model.LocationEnvelope
import com.voiid.app.model.LocationFix
import com.voiid.app.model.LiveShareView
import com.voiid.app.model.OutboundShareView
import com.voiid.app.store.LocationDao
import com.voiid.app.store.LocationLastFixRow
import com.voiid.app.store.LocationShareRow
import com.voiid.app.store.LocationShareTargetRow
import com.voiid.app.store.VoiidDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import uniffi.voiid.decryptBackup
import uniffi.voiid.encryptBackup
import uniffi.voiid.generateMasterSecret

/**
 * The share lifecycle for Feature A (location INSIDE conversations) — docs/LOCATION.md.
 *
 * THREE payload classes, three transports (the whole design):
 *  - P1 pin / P2 control (live_start/live_stop/live_rekey): DURABLE, over the E2EE MESSAGE path
 *    ([ChatEngine.sendLocationControl] 1:1 / [GroupEngine.sendGroupLocationControl] MLS).
 *    Durability is what lets a stop reach an OFFLINE recipient, and it is where the shareKey is
 *    distributed (the server never sees it).
 *  - P3 position fixes: the ephemeral WebSocket relay ONLY ([WebSocketClient.sendLocUpdate]).
 *    Never a message row, never a push, never persisted beyond the single most-recent fix.
 *
 * Inbound frames arrive through the shared [LocationRelay] seam (which the WS handler and
 * ChatEngine/GroupEngine's `_vloc` intercept feed) so this engine and the Map engine coexist.
 *
 * ONE ciphertext for the whole audience: at share start we mint `generateMasterSecret()` = 32
 * random bytes = shareKey, ship it inside live_start, then every fix is
 * `encryptBackup(shareKey, fixJSON)` — one blob decryptable by every recipient on every device.
 *
 * HONEST LIMITS (docs/LOCATION.md §11): no forward secrecy WITHIN a share (e2e-core exposes no
 * 32→32 KDF, so no key chain — a fresh random key per share is what exists). The shareKey MUST
 * come from generateMasterSecret() and MUST NEVER be a backup master secret, or `encryptBackup`'s
 * shared HKDF label ("VOIID backup key v1") derives the same AES key for both purposes.
 */
object LocationShareEngine {

    private const val TAG = "VOIID"
    private const val LIVE_CADENCE_SECONDS = 15

    @Volatile private var appContext: Context? = null
    private lateinit var tokens: TokenStore
    private lateinit var service: LocationService
    private lateinit var dao: LocationDao
    private lateinit var provider: LocationProvider
    private val chat get() = ChatEngine.get(appContext!!)
    private val group get() = GroupEngine.get(appContext!!)
    private val ws get() = WebSocketClient.get(appContext!!)

    /** shareId -> base64(raw 32-byte shareKey). The secure store, NEVER SQLite. */
    private val keyStore by lazy { SecurePrefs.open(appContext!!, "voiid_location") }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** My active outbound live shares → the persistent banner + Stop. */
    val outboundActive = mutableStateListOf<OutboundShareView>()

    /** shareId -> the live view a recipient's bubble observes. */
    val inboundViews = mutableStateMapOf<String, LiveShareView>()

    private val outbound = ConcurrentHashMap<String, Outbound>()

    private data class Outbound(
        val shareId: String,
        val conversationId: String,
        val isGroup: Boolean,
        val peerUserId: String?,          // 1:1 only
        val recipientIds: List<String>,
        val keyB64: String,
        val expiresAt: Long,              // millis
        val cadenceSeconds: Int,
        var seq: Long = 0,
        var liveStartSent: Boolean = false,
    )

    // MARK: - Init / relay wiring

    fun init(context: Context) {
        if (appContext != null) return
        synchronized(this) {
            if (appContext != null) return
            appContext = context.applicationContext
            tokens = TokenStore.get(context)
            service = LocationService(context)
            dao = VoiidDatabase.get(context).location()
            provider = LocationProvider(context)
            // Receiving side of the shared seam. Client-side authorization: a fix for a share we
            // hold no key for is dropped (docs/LOCATION.md §9, §11).
            LocationRelay.subscribeFix { shareId, from, ct, _ -> onFixFrame(shareId, from, ct) }
            LocationRelay.subscribeStop { shareId, _ -> endInbound(shareId) }
            LocationRelay.subscribeControl { plain, from, convId -> onControl(plain, from, convId) }
        }
    }

    // MARK: - Static pin (P1)

    /** Send a one-off pin. Renders a bubble immediately (local echo), then E2EE-sends it. */
    fun sendPin(context: Context, conv: ShareTarget, label: String?) {
        init(context)
        provider.currentFix { loc ->
            if (loc == null) { Log.w(TAG, "pin: no location fix available"); return@currentFix }
            val lat = round5(loc.latitude); val lon = round5(loc.longitude); val acc = loc.accuracy.toDouble()
            val env = LocationEnvelope(k = LocationEnvelope.K_PIN, t = System.currentTimeMillis(), lat = lat, lon = lon, acc = acc, label = label?.ifBlank { null })
            chat.storeLocationOutgoing(conv.conversationId, ChatEngine.LocationRef(kind = LocationEnvelope.K_PIN, lat = lat, lon = lon, acc = acc, label = label?.ifBlank { null }))
            scope.launch { sendControl(conv, env) }
        }
    }

    // MARK: - Live share (P2 + P3)

    /**
     * Start a live share. [durationSeconds] ∈ {900, 3600, 28800}. Returns null on success or an
     * error string. The caller must already have secured the runtime permission (foreground
     * always; background when duration > 15 min) — see LocationPermissions.
     */
    suspend fun startLiveShare(context: Context, conv: ShareTarget, durationSeconds: Int): String? {
        init(context)
        return try {
            val targets = if (conv.isGroup) service.conversationMemberIds(conv.conversationId).filter { it != tokens.userId }
                          else listOfNotNull(conv.peerUserId)
            if (targets.isEmpty()) return "No one to share with."
            val created = service.createShare(LocationService.KIND_CONVERSATION, conv.conversationId, targets, durationSeconds)
            val keyB64 = Base64.encodeToString(generateMasterSecret(), Base64.NO_WRAP)  // 32 random bytes
            keyStore.edit().putString(created.share_id, keyB64).apply()
            val expiresAt = parseIso(created.expires_at)
            outbound[created.share_id] = Outbound(
                shareId = created.share_id, conversationId = conv.conversationId, isGroup = conv.isGroup,
                peerUserId = conv.peerUserId, recipientIds = targets, keyB64 = keyB64,
                expiresAt = expiresAt, cadenceSeconds = LIVE_CADENCE_SECONDS,
            )
            withContext(Dispatchers.IO) {
                targets.forEach { runCatching { dao.upsertTarget(LocationShareTargetRow(created.share_id, it)) } }
                dao.upsertShare(LocationShareRow(
                    id = created.share_id, kind = "conversation", direction = "out",
                    conversationId = conv.conversationId, peerUserId = conv.peerUserId,
                    startedAt = nowSec(), expiresAt = expiresAt / 1000, endedAt = null,
                    cadenceSeconds = LIVE_CADENCE_SECONDS, state = "live",
                ))
            }
            outboundActive.add(OutboundShareView(created.share_id, conv.conversationId, expiresAt))
            // Start emitting: the FGS keeps updates flowing while backgrounded; the first fix
            // triggers the durable live_start (initial coords + the shareKey) and the bubble.
            LocationForegroundService.start(appContext!!)
            provider.startLive { loc -> onFix(loc) }
            null
        } catch (e: Exception) {
            (e as? ApiError)?.message ?: "Couldn’t start live location."
        }
    }

    private fun onFix(loc: Location) {
        val lat = round5(loc.latitude); val lon = round5(loc.longitude); val acc = loc.accuracy.toDouble()
        val now = System.currentTimeMillis()
        for (ob in outbound.values) {
            if (now >= ob.expiresAt) { scope.launch { stopShare(ob.shareId) }; continue }
            if (!ob.liveStartSent) {
                ob.liveStartSent = true
                val startEnv = LocationEnvelope(
                    k = LocationEnvelope.K_LIVE_START, s = ob.shareId, t = now, lat = lat, lon = lon, acc = acc,
                    expiresAt = ob.expiresAt, key = ob.keyB64, cadence = ob.cadenceSeconds,
                )
                // Local echo for the SENDER's own live bubble (keyless ref — key never in store).
                chat.storeLocationOutgoing(ob.conversationId, ChatEngine.LocationRef(
                    kind = LocationEnvelope.K_LIVE_START, shareId = ob.shareId, lat = lat, lon = lon, acc = acc,
                    expiresAt = ob.expiresAt, cadenceSeconds = ob.cadenceSeconds,
                ))
                scope.launch { sendControl(ShareTarget(ob.conversationId, ob.isGroup, ob.peerUserId), startEnv) }
            }
            // P3: one ciphertext for the whole audience, over the WS relay only.
            val fixEnv = LocationEnvelope(k = LocationEnvelope.K_FIX, s = ob.shareId, n = ob.seq++, t = now, lat = lat, lon = lon, acc = acc)
            val json = ApiClient.json.encodeToString(LocationEnvelope.serializer(), fixEnv)
            val ct = runCatching {
                Base64.encodeToString(encryptBackup(Base64.decode(ob.keyB64, Base64.NO_WRAP), json.toByteArray()), Base64.NO_WRAP)
            }.getOrNull() ?: continue
            ws.sendLocUpdate(ob.shareId, ob.recipientIds, ct)
        }
    }

    /** Stop ONE outbound share: instant loc_stop over WS, durable live_stop over the message
     *  path (reaches offline recipients), then DELETE the server row. Every step is best-effort
     *  except that expiresAt on both sides is the real guarantee (docs/LOCATION.md §3). */
    suspend fun stopShare(shareId: String) {
        val ob = outbound.remove(shareId)
        outboundActive.removeAll { it.shareId == shareId }
        if (ob != null) {
            runCatching { ws.sendLocStop(shareId, ob.recipientIds) }
            runCatching {
                sendControl(
                    ShareTarget(ob.conversationId, ob.isGroup, ob.peerUserId),
                    LocationEnvelope(k = LocationEnvelope.K_LIVE_STOP, s = shareId, t = System.currentTimeMillis()),
                )
            }
        }
        runCatching { service.endShare(shareId) }
        keyStore.edit().remove(shareId).apply()
        runCatching { withContext(Dispatchers.IO) { dao.markEnded(shareId, nowSec()) } }
        if (outbound.isEmpty()) {
            provider.stop()
            appContext?.let { LocationForegroundService.stop(it) }
        }
    }

    /** Revoke one recipient: stop them, then rekey the remaining audience so the removed key
     *  decrypts nothing further (docs/LOCATION.md §3.3). */
    suspend fun revokeRecipient(shareId: String, userId: String) {
        val ob = outbound[shareId] ?: return
        runCatching { service.revokeTarget(shareId, userId) }
        runCatching { ws.sendLocStop(shareId, listOf(userId)) }  // instant, that recipient only
        val remaining = ob.recipientIds.filter { it != userId }
        val newKey = Base64.encodeToString(generateMasterSecret(), Base64.NO_WRAP)
        keyStore.edit().putString(shareId, newKey).apply()
        outbound[shareId] = ob.copy(recipientIds = remaining, keyB64 = newKey)
        runCatching { withContext(Dispatchers.IO) { dao.revokeTarget(shareId, userId, nowSec()) } }
        // live_rekey (fresh key) to the remaining audience, over the durable message path.
        runCatching {
            sendControl(
                ShareTarget(ob.conversationId, ob.isGroup, ob.peerUserId),
                LocationEnvelope(k = LocationEnvelope.K_LIVE_REKEY, s = shareId, t = System.currentTimeMillis(), expiresAt = ob.expiresAt, key = newKey),
            )
        }
    }

    /** Fired from the notification Stop action / task removal — end every outbound share. */
    fun stopAllFromSystem() {
        scope.launch { outbound.keys.toList().forEach { runCatching { stopShare(it) } } }
    }

    /** Non-suspend entry point for UI (a bubble/banner Stop tap). */
    fun stopShareUi(shareId: String) {
        scope.launch { runCatching { stopShare(shareId) } }
    }

    // MARK: - Inbound (from the shared LocationRelay seam)

    /** A decrypted durable control envelope (`_vloc`) off the ratchet/MLS. Lifts the shareKey,
     *  drives share state, and renders the pin / live_start bubble. */
    private fun onControl(plaintextJson: String, ownerUserId: String, conversationId: String) {
        val env = parseEnvelope(plaintextJson) ?: return
        val shareId = env.s
        val createdAt = if (env.t > 0) env.t else System.currentTimeMillis()
        when (env.k) {
            LocationEnvelope.K_PIN -> {
                if (env.lat == null || env.lon == null) return
                val ref = ChatEngine.LocationRef(kind = LocationEnvelope.K_PIN, lat = env.lat, lon = env.lon, acc = env.acc ?: 0.0, label = env.label)
                chat.storeLocationInbound(conversationId, "locpin_${ownerUserId}_${env.t}", ownerUserId, ref, createdAt)
            }
            LocationEnvelope.K_LIVE_START -> {
                if (shareId == null) return
                val keyB64 = env.key ?: return
                keyStore.edit().putString(shareId, keyB64).apply()
                val expiresAt = env.expiresAt ?: (createdAt + 3_600_000L)
                val cadence = env.cadence ?: LIVE_CADENCE_SECONDS
                val initial = if (env.lat != null && env.lon != null)
                    LocationFix(shareId, ownerUserId, env.lat, env.lon, env.acc ?: 0.0, 0, createdAt) else null
                scope.launch {
                    withContext(Dispatchers.IO) {
                        dao.upsertShare(LocationShareRow(
                            id = shareId, kind = "conversation", direction = "in",
                            conversationId = conversationId, peerUserId = ownerUserId,
                            startedAt = createdAt / 1000, expiresAt = expiresAt / 1000, endedAt = null,
                            cadenceSeconds = cadence, state = "live",
                        ))
                        initial?.let { dao.upsertLastFix(LocationLastFixRow(shareId, ownerUserId, it.lat, it.lon, it.acc, 0, it.fixedAt / 1000)) }
                    }
                    inboundViews[shareId] = LiveShareView(shareId, ownerUserId, expiresAt, cadence, initial, endedExplicit = false)
                }
                if (env.lat != null && env.lon != null) {
                    val ref = ChatEngine.LocationRef(kind = LocationEnvelope.K_LIVE_START, shareId = shareId, lat = env.lat, lon = env.lon, acc = env.acc ?: 0.0, expiresAt = expiresAt, cadenceSeconds = cadence)
                    chat.storeLocationInbound(conversationId, "loclive_$shareId", ownerUserId, ref, createdAt)
                }
            }
            LocationEnvelope.K_LIVE_REKEY -> {
                if (shareId == null) return
                env.key?.let { keyStore.edit().putString(shareId, it).apply() }
                env.expiresAt?.let { newExp -> inboundViews[shareId]?.let { inboundViews[shareId] = it.copy(expiresAt = newExp) } }
            }
            LocationEnvelope.K_LIVE_STOP -> shareId?.let { endInbound(it) }
        }
    }

    private fun onFixFrame(shareId: String, fromUserId: String, ciphertextB64: String) {
        val keyB64 = keyStore.getString(shareId, null) ?: return       // unknown share_id → drop
        val view = inboundViews[shareId] ?: return
        val env = runCatching {
            val bytes = decryptBackup(Base64.decode(keyB64, Base64.NO_WRAP), Base64.decode(ciphertextB64, Base64.NO_WRAP))
            parseEnvelope(String(bytes))
        }.getOrNull() ?: return
        if (env.k != LocationEnvelope.K_FIX || env.lat == null || env.lon == null) return
        val seq = env.n ?: return
        val prev = view.lastFix
        if (prev != null && seq <= prev.seq) return   // out-of-order relay frame → drop, never a jump back
        val fix = LocationFix(shareId, fromUserId, env.lat, env.lon, env.acc ?: 0.0, seq, if (env.t > 0) env.t else System.currentTimeMillis())
        inboundViews[shareId] = view.copy(lastFix = fix)
        scope.launch { withContext(Dispatchers.IO) { runCatching { dao.upsertLastFix(LocationLastFixRow(shareId, fromUserId, fix.lat, fix.lon, fix.acc, seq, fix.fixedAt / 1000)) } } }
    }

    private fun endInbound(shareId: String) {
        keyStore.edit().remove(shareId).apply()
        inboundViews[shareId]?.let { inboundViews[shareId] = it.copy(endedExplicit = true) }
        scope.launch { withContext(Dispatchers.IO) { runCatching { dao.markEnded(shareId, nowSec()) } } }
    }

    /** Reconcile with the server on chat-screen entry: surface still-running outbound shares
     *  (so a relinked device can Stop them) and hydrate inbound expiries from the durable set. */
    fun refresh(context: Context) {
        init(context)
        scope.launch {
            val res = runCatching { service.listShares() }.getOrNull() ?: return@launch
            for (s in res.outbound) {
                if (outbound.containsKey(s.share_id)) continue
                val keyB64 = keyStore.getString(s.share_id, null) ?: continue
                val convId = s.conversation_id ?: continue
                val expiresAt = parseIso(s.expires_at)
                // Reconstructed context: Stop works (loc_stop + endShare). We do NOT resume
                // emission here — one emitting device per share, and the timer still guards it.
                outbound[s.share_id] = Outbound(
                    shareId = s.share_id, conversationId = convId, isGroup = false, peerUserId = null,
                    recipientIds = s.target_user_ids, keyB64 = keyB64, expiresAt = expiresAt,
                    cadenceSeconds = LIVE_CADENCE_SECONDS, liveStartSent = true,
                )
                if (outboundActive.none { it.shareId == s.share_id })
                    outboundActive.add(OutboundShareView(s.share_id, convId, expiresAt))
            }
            for (s in res.inbound) {
                val keyB64 = keyStore.getString(s.share_id, null) ?: continue
                if (inboundViews.containsKey(s.share_id)) continue
                val last = runCatching { withContext(Dispatchers.IO) { dao.lastFix(s.share_id) } }.getOrNull()
                val fix = last?.let { LocationFix(it.shareId, it.senderUserId, it.lat, it.lon, it.acc, it.seq, it.fixedAt * 1000) }
                inboundViews[s.share_id] = LiveShareView(s.share_id, s.owner_user_id, parseIso(s.expires_at), LIVE_CADENCE_SECONDS, fix, endedExplicit = false)
            }
        }
    }

    // MARK: - Message-path send (durable) via ChatEngine (1:1) / GroupEngine (MLS)

    private suspend fun sendControl(conv: ShareTarget, env: LocationEnvelope) {
        val json = ApiClient.json.encodeToString(LocationEnvelope.serializer(), env)
        runCatching {
            if (conv.isGroup) group.sendGroupLocationControl(conv.conversationId, json)
            else chat.sendLocationControl(json, conv.conversationId, conv.peerUserId ?: return)
        }.onFailure { Log.e(TAG, "location control send failed k=${env.k}", it) }
    }

    // MARK: - Reads for the UI

    /** One decoded inbound share for a bubble to observe (null = we hold no key / never started). */
    fun inbound(shareId: String?): LiveShareView? = shareId?.let { inboundViews[it] }

    /** Whether shareId is one of MY active outbound shares (drives the Stop button on my bubble). */
    fun isMineActive(shareId: String?): Boolean = shareId != null && outbound.containsKey(shareId)

    private fun parseEnvelope(json: String): LocationEnvelope? =
        runCatching { ApiClient.json.decodeFromString(LocationEnvelope.serializer(), json) }
            .getOrNull()?.takeIf { it.vloc == LocationEnvelope.VLOC }

    private fun round5(d: Double): Double = Math.round(d * 1e5) / 1e5
    private fun nowSec(): Long = System.currentTimeMillis() / 1000
    private fun parseIso(s: String): Long =
        runCatching { java.time.Instant.parse(s).toEpochMilli() }.getOrDefault(System.currentTimeMillis())
}

/** Where a share is directed: a 1:1 peer or a group conversation. */
data class ShareTarget(
    val conversationId: String,
    val isGroup: Boolean,
    val peerUserId: String?,   // 1:1 only
)

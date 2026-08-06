package com.voiid.app.net

import android.content.Context
import android.util.Base64
import android.util.Log
import com.voiid.app.model.MapConstants
import com.voiid.app.model.MapContact
import com.voiid.app.model.MapEnvelope
import com.voiid.app.model.MapFix
import com.voiid.app.model.MapSubject
import com.voiid.app.model.MapSubjectState
import com.voiid.app.model.MapVisibility
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import uniffi.voiid.decryptBackup
import uniffi.voiid.encryptBackup
import uniffi.voiid.generateMasterSecret

/**
 * Feature (B) — The Map — the whole outbound + inbound presence machinery, minus the pixels.
 *
 * SAFETY POSTURE, enforced here in code, not just UI (§8):
 *  - Default is [MapVisibility.GHOST]. NO server row and NO location request exists until the
 *    user explicitly names individuals ([setAudience] with a non-empty list, then [goVisible]).
 *  - Ghost Mode is a HARD LOCAL GATE: while ghosted the fused provider is never started, so the
 *    fix is never taken. Not "we filter it server-side".
 *  - Turning ghost OFF mints a FRESH shareKey and redistributes it, so the ghosted period is
 *    cryptographically dark — anyone holding the old key sees nothing new (§8).
 *  - Coordinates are rounded to ~110 m at the source (MapLocationProvider) before encryption.
 *
 * The shareKey is one random 32-byte [generateMasterSecret] per share. There is NO forward
 * secrecy within a share (e2e-core exposes no 32→32 KDF, §11); a fresh key per share preserves
 * FS across shares. The key comes from generateMasterSecret and MUST NEVER be a backup master
 * secret — encryptBackup's HKDF label is shared with real backups (§1 trap).
 *
 * Storage: allow-list, ghost state and keys live in an encrypted prefs file ([SecurePrefs]),
 * never in SQLite — so this feature adds ZERO Room migrations (deliberate: the local DB is being
 * evolved concurrently by other features and a version bump here would collide). The subject
 * cache is in memory only, which satisfies "wipe anything older than 8 h on cold start" for free.
 */
object MapPresenceEngine {

    private const val TAG = "VoiidMap"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var ctx: Context? = null
    @Volatile private var tokens: TokenStore? = null
    @Volatile private var service: MapPresenceService? = null
    @Volatile private var provider: MapLocationProvider? = null
    @Volatile private var chat: ChatEngine? = null
    @Volatile private var ws: WebSocketClient? = null

    // ---- observable state (Compose collects these) --------------------------------------

    private val _visibility = MutableStateFlow(MapVisibility.GHOST)
    val visibility: StateFlow<MapVisibility> = _visibility.asStateFlow()

    /** Epoch millis until which a TIMED ghost holds; 0 = ghost is manual ("until I turn it off"). */
    private val _ghostUntil = MutableStateFlow(0L)
    val ghostUntil: StateFlow<Long> = _ghostUntil.asStateFlow()

    /** My outbound allow-list — the people who can see me. Empty by default. */
    private val _audience = MutableStateFlow<List<MapContact>>(emptyList())
    val audience: StateFlow<List<MapContact>> = _audience.asStateFlow()

    /** The people I can see (they added me): subject id → subject. In memory only. */
    private val _subjects = MutableStateFlow<Map<String, MapSubject>>(emptyMap())
    val subjects: StateFlow<Map<String, MapSubject>> = _subjects.asStateFlow()

    /**
     * Everyone who has handed us a `map_key` — i.e. who has made themselves visible to us.
     * Persisted, unlike [_subjects], which only ever gains an entry when a live fix decrypts
     * IN THIS PROCESS. Without this the map was blank until a friend's next fix happened to
     * land while the app was open: a contact who was genuinely sharing showed nothing at all,
     * and nothing survived a restart. iOS has the same set as `inboundSenders`.
     *
     * A sender here with no entry in [_subjects] is "sharing, waiting for their first fix".
     */
    private val _waitingSenders = MutableStateFlow<Set<String>>(emptySet())
    val waitingSenders: StateFlow<Set<String>> = _waitingSenders.asStateFlow()

    /** True once the user has made the first Browse-only / Choose-who decision (§8 explainer). */
    private val _onboarded = MutableStateFlow(false)
    val onboarded: StateFlow<Boolean> = _onboarded.asStateFlow()

    /**
     * Last user-facing failure from the share lifecycle, or null. The Map MUST NOT claim you
     * are visible when the share row never opened — that is a safety lie: the user believes
     * chosen contacts can see them while nothing is published. Cleared on the next success.
     */
    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    fun clearError() { _lastError.value = null }

    // ---- outbound share state -----------------------------------------------------------

    /**
     * The user's INTENT to be visible, kept separate from [_visibility] (which is the
     * CONFIRMED state — the server row exists). A failed create leaves intent true and
     * visibility GHOST, so [onForeground] retries without ever having lied to the user.
     * Cleared only by an explicit ghost/kill-switch.
     */
    @Volatile private var wantsVisible: Boolean = false

    @Volatile private var shareId: String? = null
    @Volatile private var shareKey: ByteArray? = null       // my current outbound shareKey
    @Volatile private var expiresAt: Long = 0L
    @Volatile private var seq: Long = 0L

    // ---- inbound share registry (people who added me) -----------------------------------

    private data class InboundShare(val fromUserId: String, val key: ByteArray, val expiresAt: Long)
    // subjectSeq tracks the last drawn seq per share so an out-of-order relay frame is dropped.
    private val inbound = HashMap<String, InboundShare>()
    private val subjectSeq = HashMap<String, Long>()

    @Serializable private data class PersistedInbound(val shareId: String, val from: String, val key: String, val expiresAt: Long)

    // ---- lifecycle ----------------------------------------------------------------------

    fun init(context: Context) {
        if (ctx != null) return
        synchronized(this) {
            if (ctx != null) return
            val app = context.applicationContext
            ctx = app
            tokens = TokenStore.get(app)
            service = MapPresenceService(tokens!!)
            provider = MapLocationProvider(app)
            chat = ChatEngine.get(app)
            ws = WebSocketClient.get(app)
            restore()
            subscribe()

            // RESUME THE STREAM ON COLD START.
            //
            // `restore()` rebuilds the STATE — visibility, share id, share key, audience —
            // but nothing was starting the location provider again, so after a kill the app
            // came back believing it was visible while emitting nothing. The user had to
            // remove and re-add their audience to get it going, which is exactly the reported
            // flow.
            //
            // Guarded on the share being real AND unexpired: a restored VISIBLE with a lapsed
            // server row would emit against a share the backend has already dropped, and the
            // fixes would go nowhere. onForeground() re-opens that case properly.
            if (_visibility.value == MapVisibility.VISIBLE &&
                shareId != null && shareKey != null && expiresAt > now()
            ) {
                provider?.start { lat, lon, acc -> emitFix(lat, lon, acc) }
                provider?.startBackground()
                provider?.requestSingle { lat, lon, acc -> emitFix(lat, lon, acc) }
            }
        }
    }

    private fun subscribe() {
        LocationRelay.subscribeFix { shareId, from, ct, ts -> onFix(shareId, from, ct, ts) }
        LocationRelay.subscribeStop { shareId, from, kind, reason -> onStop(shareId, from, kind, reason) }
        LocationRelay.subscribeControl { plain, from, _ -> onControl(plain, from) }
    }

    // ---- audience allow-list ------------------------------------------------------------

    /**
     * Replace the allow-list. Persisted immediately (local-first). If we are currently visible,
     * this re-opens the share against the new set and hands the fresh audience a new key — a
     * removed contact's key decrypts nothing further (§3 revocation).
     */
    fun setAudience(contacts: List<MapContact>) {
        val deduped = contacts.distinctBy { it.userId }
        val previous = _audience.value
        // Diff BEFORE replacing the list: a removed contact is no longer in `_audience`, and
        // broadcastControl() only reaches the current audience, so they would never be told.
        val removed = previous.filter { old -> deduped.none { it.userId == old.userId } }
        val wasVisible = _visibility.value == MapVisibility.VISIBLE
        val activeShareId = shareId

        _audience.value = deduped
        persist()

        if (wasVisible && removed.isNotEmpty()) {
            // Revocation is a three-part act (§3), and Android previously did NONE of it —
            // it just re-opened the share and relied on the server superseding it. That left
            // the removed contact holding a working key, never told to stop, still rendering
            // our last known position. All three parts matter:
            //   1. loc_stop over WS      — a live viewer erases us immediately
            //   2. durable map_off       — an offline viewer erases us when they next sync
            //   3. DELETE /targets/:uid  — the server stops routing to them at all
            // The rekey in openShare(rekey = true) below then makes their key useless for
            // any FUTURE fix. (Revocation cannot un-see a fix already delivered.)
            val removedIds = removed.map { it.userId }
            if (activeShareId != null) {
                ws?.sendLocStop(activeShareId, removedIds)
                sendControlTo(MapEnvelope(k = "map_off", s = activeShareId, t = now()), removed)
                scope.launch {
                    for (id in removedIds) {
                        runCatching { service?.revokeTarget(activeShareId, id) }
                            .onFailure { Log.w(TAG, "map revokeTarget failed for $id", it) }
                    }
                }
            }
            Log.i(TAG, "map audience: revoked ${removedIds.size} contact(s), rekeying")
        }

        if (wasVisible) {
            // Rekey on ANY change so a removed contact's key decrypts nothing further.
            if (deduped.isEmpty()) goGhost(0L) else scope.launch { openShare(rekey = true) }
        }
    }

    /**
     * Drop ONE person from the allow-list — the manage sheet's per-person Remove.
     *
     * Deliberately routed through [setAudience] rather than editing `_audience` directly, so a
     * single removal gets the exact same three-part revocation (loc_stop, durable map_off,
     * DELETE /targets) plus rekey as a bulk change. A separate code path here would be a second
     * place for revocation to be forgotten.
     */
    fun removeFromAudience(userId: String) {
        val next = _audience.value.filterNot { it.userId == userId }
        if (next.size == _audience.value.size) return
        setAudience(next)
    }

    fun markOnboarded() { _onboarded.value = true; persist() }

    // ---- visibility ---------------------------------------------------------------------

    /**
     * Become visible to the current allow-list. No-op with an empty list — you cannot become
     * visible to no one, and "visible to everyone" does not exist (§8). Mints/refreshes the
     * shareKey, opens the server row, distributes the key, and starts the coarse provider.
     */
    fun goVisible() {
        if (_audience.value.isEmpty()) return
        _lastError.value = null
        wantsVisible = true
        // Do NOT flip to VISIBLE here. openShare() sets it only once the server row exists,
        // so a failed create can never leave the UI claiming "you are visible" while nothing
        // is being published. `_ghostUntil` is cleared up-front because the user's INTENT to
        // stop ghosting is real regardless of whether the network call succeeds.
        _ghostUntil.value = 0L
        persist()
        scope.launch { openShare(rekey = true) }
    }

    /**
     * Ghost. Instant + local-first: stop emitting NOW (the fix is no longer taken), tell live
     * sockets, send a durable map_off so an offline viewer still learns, and delete the row.
     * [until] is epoch millis for a timed ghost, or 0 for "until I turn it off".
     */
    fun goGhost(until: Long) {
        // MUST clear the intent, or the next onForeground() would re-open a share and put the
        // user back on the map after they explicitly went dark.
        wantsVisible = false
        _visibility.value = MapVisibility.GHOST
        _ghostUntil.value = until
        provider?.stop()
        val id = shareId
        val recips = _audience.value.map { it.userId }
        if (id != null) {
            ws?.sendLocStop(id, recips)
            // Durable "I've gone dark" so an offline viewer erases me even without the WS frame.
            broadcastControl(MapEnvelope(k = "map_off", s = id, t = now()))
            scope.launch { service?.delete(id) }
        }
        // Wipe the outbound key so the ghosted window is cryptographically dark.
        shareKey = null
        shareId = null
        expiresAt = 0L
        persist()
    }

    /** Settings → Privacy → Stop all location sharing / long-press the Map tab (§8 kill switch). */
    fun killSwitch() = goGhost(0L)

    /** Foreground tick: honour a timed ghost's expiry, refresh the 24 h auto-ghost, prune subjects. */
    fun onForeground() {
        val until = _ghostUntil.value
        if (_visibility.value == MapVisibility.GHOST && until != 0L && now() >= until) {
            // A timed ghost elapsed — but we do NOT silently re-appear; the user re-enables.
            _ghostUntil.value = 0L
            persist()
        }
        // Retry on INTENT, not on confirmed visibility — a create that failed while offline
        // leaves us intent-visible but state-ghost, and this is the retry that recovers it.
        if (wantsVisible) {
            val id = shareId
            if (id != null && _visibility.value == MapVisibility.VISIBLE) {
                scope.launch {
                    runCatching { service?.extend(id, MapConstants.MAP_MAX_DURATION_SECONDS.toLong()) }
                        .onSuccess { expiresAt = now() + MapConstants.MAP_MAX_DURATION_SECONDS * 1000L }
                        // A silently-failed extend used to let the server-side ceiling lapse
                        // while we kept emitting against an expired row.
                        .onFailure { Log.w(TAG, "map share extend failed for $id", it) }
                }
                // RESTART THE STREAM, not just a one-shot.
                //
                // This called `requestSingle` alone, so reopening the app sent exactly ONE
                // fix and then went quiet — the pin updated once and froze, which is
                // indistinguishable from sharing having stopped. `start` is what keeps it
                // flowing; it is idempotent (it calls stop() first), so a second foreground
                // does not stack callbacks.
                //
                // startBackground too: onBackground() leaves the PendingIntent registered,
                // but a process that was KILLED lost the in-process half, and re-registering
                // costs nothing.
                provider?.start { lat, lon, acc -> emitFix(lat, lon, acc) }
                provider?.startBackground()
                provider?.requestSingle { lat, lon, acc -> emitFix(lat, lon, acc) }
            } else {
                // Intent-visible but no live share — the row lapsed while we were away, or a
                // create failed offline. Re-open it; openShare() restarts the provider.
                scope.launch { openShare(rekey = false) }
            }
        }
        recomputeSubjects()
    }

    fun onBackground() {
        // Stop the FOREGROUND stream only — the background PendingIntent registration stays.
        //
        // This used to call `provider.stop()`, which now also cancels background delivery, so
        // it tore down the whole thing the instant the app was backgrounded and undid the
        // point of having it. `stopForeground()` drops the in-process callback (which cannot
        // survive anyway) and leaves the OS-held registration alone.
        //
        // Ghost Mode and the kill switch still call the full `stop()` — going dark must cancel
        // BOTH, and that distinction is the whole reason these are now separate methods.
        provider?.stopForeground()
    }

    // ---- outbound: open share + emit ----------------------------------------------------

    private suspend fun openShare(rekey: Boolean) {
        val svc = service ?: return
        val contacts = _audience.value
        if (contacts.isEmpty()) return
        if (rekey || shareKey == null) shareKey = generateMasterSecret()
        val resp = runCatching {
            svc.create(contacts.map { it.userId }, MapConstants.MAP_MAX_DURATION_SECONDS.toLong())
        }.getOrElse { e ->
            // Row couldn't be created (offline / server down). Report it and stay GHOST: the
            // user must not be told they are visible when nothing is published. Retried on the
            // next foreground, which re-enters here while the intent is still VISIBLE.
            Log.w(TAG, "map share create FAILED — staying ghost", e)
            _lastError.value = "Couldn't start sharing your location. Check your connection and try again."
            return
        }
        shareId = resp.share_id
        expiresAt = now() + MapConstants.MAP_MAX_DURATION_SECONDS * 1000L
        // Only NOW is the claim true: the server row exists and the key is about to go out.
        _visibility.value = MapVisibility.VISIBLE
        _lastError.value = null
        persist()
        // Distribute the fresh key to each contact over their 1:1 ratchet.
        val keyB64 = Base64.encodeToString(shareKey, Base64.NO_WRAP)
        val env = MapEnvelope(
            k = "map_key", s = resp.share_id, t = now(), expiresAt = expiresAt,
            key = keyB64, cadence = MapConstants.PRESENCE_CADENCE_SECONDS,
        )
        broadcastControl(env)
        // Start (or restart) the coarse provider — but ONLY if not ghosted (hard gate).
        if (_visibility.value == MapVisibility.VISIBLE) {
            provider?.start { lat, lon, acc -> emitFix(lat, lon, acc) }
            provider?.requestSingle { lat, lon, acc -> emitFix(lat, lon, acc) }
            // ALSO register the PendingIntent stream, which survives the app being killed.
            // The in-process callback above is the responsive one while Voiid is alive; this
            // is what stops the pin freezing the moment Android reclaims the process. Both
            // are cheap and idempotent, and goGhost()/killSwitch() tear down both via
            // provider.stop().
            provider?.startBackground()
        }
    }

    /**
     * A background fix arrived, possibly with the app process starting COLD to receive it.
     *
     * THE KILL PROBLEM. `requestLocationUpdates(request, callback, looper)` binds delivery to
     * an in-process object, so Android killing the app — which it does aggressively when
     * backgrounded, and immediately on a swipe from Recents — took the Map's location stream
     * with it. The pin then froze wherever the user last had Voiid open, telling their
     * contacts they were somewhere they had left. Delivery is now a PendingIntent broadcast
     * (see MapLocationReceiver), which the OS holds and which restarts the process.
     *
     * Everything this needs — visibility, share id, share key, audience — is in
     * SharedPreferences, so `init` rebuilds it from disk. That also means GHOST MODE SURVIVES
     * A KILL: if the user ghosted, `restore()` reads VISIBLE = false and `emitFix` refuses,
     * even though the OS still had a live registration when the process died.
     *
     * The socket may not be connected on a cold start. That is fine and deliberate: a missed
     * ambient fix is a pin a few minutes stale, and forcing a connect on every background
     * wake would cost far more than it is worth for a 500 m-accurate position.
     */
    fun handleBackgroundFix(context: Context, lat: Double, lon: Double, acc: Double?) {
        init(context)
        if (_visibility.value != MapVisibility.VISIBLE) {
            // Registration outlived the user's decision — cancel it now that we are alive to
            // do so, rather than waking again for a position we will refuse to send.
            provider?.stopBackground()
            return
        }
        emitFix(lat, lon, acc)
    }

    private fun emitFix(lat: Double, lon: Double, acc: Double?) {
        if (_visibility.value != MapVisibility.VISIBLE) return   // ghost hard-gate, belt & braces
        val key = shareKey ?: return
        val id = shareId ?: return
        val recips = _audience.value.map { it.userId }
        if (recips.isEmpty()) return
        val env = MapEnvelope(k = "fix", s = id, t = now(), n = ++seq, lat = lat, lon = lon, acc = acc)
        val json = ApiClient.json.encodeToString(MapEnvelope.serializer(), env)
        val blob = runCatching { encryptBackup(key, json.encodeToByteArray()) }.getOrNull() ?: return
        val ct = Base64.encodeToString(blob, Base64.NO_WRAP)
        ws?.sendLocUpdate(id, recips, ct)
    }

    /** Send a durable control envelope to every contact over their 1:1 ratchet (silent, no bubble). */
    private fun broadcastControl(env: MapEnvelope) = sendControlTo(env, _audience.value)

    /**
     * Send a durable control envelope to an EXPLICIT recipient list. Needed for revocation,
     * where the target has already been removed from `_audience` and so cannot be reached by
     * [broadcastControl] — the reason a removed contact was never told to erase us.
     */
    private fun sendControlTo(env: MapEnvelope, recipients: List<MapContact>) {
        val engine = chat ?: return
        val json = ApiClient.json.encodeToString(MapEnvelope.serializer(), env)
        for (c in recipients) {
            scope.launch {
                runCatching { engine.sendLocationControl(json, c.conversationId, c.userId) }
                    // A failed map_key means that contact can never decrypt us; a failed
                    // map_off means they keep showing a stale position. Both were silent.
                    .onFailure { Log.w(TAG, "map ${env.k} send to ${c.userId} failed", it) }
            }
        }
    }

    // ---- inbound: decode others' presence ----------------------------------------------

    private fun onControl(plaintextJson: String, fromUserId: String) {
        val env = runCatching { ApiClient.json.decodeFromString(MapEnvelope.serializer(), plaintextJson) }
            .getOrElse {
                Log.w(TAG, "map control from $fromUserId: envelope decode failed", it)
                return
            }
        // Discriminate on KIND, not on _vloc. `vloc` is only a version hint, and rejecting on
        // it means a future peer bumping the version silently kills every control message with
        // no trace. iOS made the same field tolerant for exactly this reason.
        if (env.vloc != 1) Log.w(TAG, "map control from $fromUserId: unexpected _vloc=${env.vloc}, processing anyway")
        when (env.k) {
            "map_key" -> {
                val id = env.s ?: run { Log.w(TAG, "map_key from $fromUserId: missing share id"); return }
                val keyB64 = env.key ?: run { Log.w(TAG, "map_key from $fromUserId: missing key"); return }
                val key = runCatching { Base64.decode(keyB64, Base64.NO_WRAP) }.getOrElse {
                    Log.w(TAG, "map_key from $fromUserId: key is not valid base64", it)
                    return
                }
                // Same fallback as the background capture path in ChatEngine — these MUST
                // agree, or a key captured in the foreground expires hours before the very
                // same key captured while backgrounded. See MapConstants.DEFAULT_KEY_TTL_MS.
                inbound[id] = InboundShare(fromUserId, key,
                    env.expiresAt ?: (now() + MapConstants.DEFAULT_KEY_TTL_MS))
                // Record the sender NOW, so they show as "sharing — waiting for location"
                // immediately, instead of only when their first fix happens to decrypt while
                // the app is open. This is what made the map look permanently empty.
                noteWaitingSender(fromUserId)
                Log.i(TAG, "map_key captured from $fromUserId share=$id")
                persist()
            }
            "map_off" -> {
                val id = env.s
                // Explicit stop ERASES the cached position — the subject leaves the map entirely
                // and shows "Not sharing" with NO last position (§8: erase vs age-out).
                if (id != null) inbound.remove(id)
                subjectSeq.remove(id)
                eraseSubject(fromUserId)
                persist()
            }
        }
    }

    private fun onFix(fixShareId: String, fromUserId: String, ciphertextB64: String, ts: Long) {
        // Client-side authorization: a fix for a share we hold no key for is discarded (§9).
        // Fall back to the background-safe key store: the `map_key` may have arrived while the
        // app was killed/backgrounded (captured by ChatEngine into MapInboundKeyStore), so it
        // isn't in our in-memory registry yet. Without this, every fix from a contact who
        // started sharing while we were away is dropped — the "others never appear" bug.
        // Every step below is logged on failure. This whole chain used to be
        // `runCatching{}.getOrNull() ?: return` with no logging at all, which made "no key
        // yet", "stale key after a rekey", "corrupt frame" and "schema mismatch" completely
        // indistinguishable AND invisible — a fix that never drew left no trace to debug.
        val share = inbound[fixShareId] ?: restoreInboundKey(fixShareId) ?: run {
            Log.w(TAG, "map fix DROPPED share=$fixShareId from=$fromUserId: no inbound key held")
            return
        }
        val blob = runCatching { Base64.decode(ciphertextB64, Base64.NO_WRAP) }.getOrElse {
            Log.w(TAG, "map fix DROPPED share=$fixShareId: ciphertext not valid base64", it)
            return
        }
        val plain = runCatching { decryptBackup(share.key, blob) }.getOrElse {
            Log.w(TAG, "map fix DROPPED share=$fixShareId: decrypt failed (stale key — sender likely rekeyed)", it)
            return
        }
        val env = runCatching { ApiClient.json.decodeFromString(MapEnvelope.serializer(), plain.decodeToString()) }
            .getOrElse {
                Log.w(TAG, "map fix DROPPED share=$fixShareId: envelope decode failed", it)
                return
            }
        if (env.k != "fix") {
            Log.w(TAG, "map fix DROPPED share=$fixShareId: unexpected kind ${env.k}")
            return
        }
        // Version is a hint, not a gate — see onControl.
        if (env.vloc != 1) Log.w(TAG, "map fix share=$fixShareId: unexpected _vloc=${env.vloc}, processing anyway")
        val lat = env.lat ?: run { Log.w(TAG, "map fix DROPPED share=$fixShareId: no lat"); return }
        val lon = env.lon ?: run { Log.w(TAG, "map fix DROPPED share=$fixShareId: no lon"); return }
        val n = env.n ?: 0L
        // Drop an out-of-order relay frame rather than rendering a jump backwards.
        val last = subjectSeq[fixShareId] ?: -1L
        if (n <= last) {
            Log.d(TAG, "map fix ignored share=$fixShareId: out-of-order seq $n <= $last")
            return
        }
        subjectSeq[fixShareId] = n
        val fix = MapFix(share.fromUserId, fixShareId, lat, lon, env.acc, n, env.t ?: ts)
        val subject = MapSubject(share.fromUserId, fix, MapSubjectState.LIVE)
        _subjects.value = _subjects.value.toMutableMap().apply { put(share.fromUserId, subject) }
    }

    /** Lift a background-captured inbound map key into the in-memory registry (and persist it
     *  into the engine's own store), so subsequent fixes for this share decrypt in-process. */
    private fun restoreInboundKey(shareId: String): InboundShare? {
        val c = ctx ?: return null
        val e = MapInboundKeyStore.get(c, shareId) ?: return null
        val share = InboundShare(e.fromUserId, e.key, e.expiresAt)
        inbound[shareId] = share
        persist()
        return share
    }

    private fun onStop(stopShareId: String, fromUserId: String, kind: String, reason: String) {
        // A stop the API stamped `conversation` is the chat live-share feature's and can never
        // be about the Map. Free early-out; the registry test below is still the real guard,
        // since a stop relayed from another client carries no kind at all.
        if (kind == "conversation") return

        // ONLY ACT ON A STOP FOR A SHARE *THIS* ENGINE IS TRACKING.
        //
        // THE BUG: the Map and the chat live-share engine both consume the same
        // LocationRelay stop stream, so ending a conversation live-share reached here too —
        // and `eraseSubject` removed the sender from the Map entirely. Stopping a chat share
        // with someone made them vanish from Friends Map, a different feature they had not
        // turned off. Mirrors the iOS fix.
        //
        // `inbound` holds only MAP shares (they are the ones that arrived with a map_key), so
        // its membership IS the test: an unknown id belongs to the chat feature, or to a share
        // we already forgot. Neither is a reason to erase the person.
        //
        // The background key store is the second half of that same test, and consulting it is
        // what makes a stop land at all when the map_key was captured while we were dead and
        // no fix has decrypted in-process yet: memory-only, the stop was dropped, the key
        // survived, and the sender stayed "sharing" for someone who had gone dark.
        val share = inbound[stopShareId]
            ?: ctx?.let { MapInboundKeyStore.get(it, stopShareId) }?.let { InboundShare(it.fromUserId, it.key, it.expiresAt) }
            ?: return

        // A SUPERSEDE IS NOT "WENT DARK".
        //
        // The server retires the previous row every time a sender recreates their map share —
        // adding one person to their audience, re-arming on foreground, a retried openShare —
        // and publishes a stop for the OLD id to the whole audience. Erasing the subject there
        // made the pin vanish on every re-open and stay gone until a fresh `map_key` AND the
        // next 5-minute fix had both landed. The person is still sharing: drop the dead id from
        // the live registry (no fix will ever carry it again) and keep everything else. The
        // persisted key entry is deliberately left alone — it is what holds them in
        // [_waitingSenders] across the gap until the replacement `map_key` arrives.
        if (reason == "superseded") {
            inbound.remove(stopShareId)
            subjectSeq.remove(stopShareId)
            persist()
            return
        }

        inbound.remove(stopShareId)
        ctx?.let { MapInboundKeyStore.remove(it, stopShareId) }
        subjectSeq.remove(stopShareId)
        // The owner recorded with the key came over the E2EE ratchet; the relay frame's sender
        // is whatever the socket said. Erase the person whose share this actually is.
        eraseSubject(share.fromUserId.ifEmpty { fromUserId })
        persist()
    }

    private fun eraseSubject(userId: String) {
        // Explicit stop → the subject disappears with no last position retained, and they are
        // no longer "waiting" either: they have gone dark, not merely not-yet-fixed.
        _subjects.value = _subjects.value.toMutableMap().apply { remove(userId) }
        forgetWaitingSender(userId)
    }

    /** They handed us a key — they are sharing with us, even before their first fix lands. */
    private fun noteWaitingSender(userId: String) {
        if (userId.isEmpty() || _waitingSenders.value.contains(userId)) return
        _waitingSenders.value = _waitingSenders.value + userId
    }

    private fun forgetWaitingSender(userId: String) {
        if (!_waitingSenders.value.contains(userId)) return
        _waitingSenders.value = _waitingSenders.value - userId
    }

    /** Re-derive every subject's state from its fix age (§8). Works with zero network. */
    fun recomputeSubjects() {
        val now = now()
        val next = _subjects.value.toMutableMap()
        val iter = next.entries.iterator()
        while (iter.hasNext()) {
            val e = iter.next()
            val fix = e.value.fix ?: continue
            val age = now - fix.fixedAt
            val state = when {
                age < MapConstants.LIVE_MAX_AGE_MS -> MapSubjectState.LIVE
                age < MapConstants.STALE_MAX_AGE_MS -> MapSubjectState.STALE
                else -> MapSubjectState.AGED_OUT   // keep the last position, move to the list
            }
            e.setValue(e.value.copy(state = state))
        }
        _subjects.value = next
        // Off the caller's thread: this reads the encrypted key store, and recompute runs on a
        // 30 s UI tick.
        scope.launch { pruneWaitingSenders() }
    }

    /**
     * Drop anyone from [_waitingSenders] we hold no key for in EITHER store.
     *
     * A durable `map_off` handled by BACKGROUND sync alone (ChatEngine removes the key from
     * [MapInboundKeyStore] and nothing else) never reaches [onControl], so the sender was left
     * showing "sharing — waiting for location" indefinitely for someone who had gone dark.
     * Key expiry lands here too: [MapInboundKeyStore.senders] treats a lapsed entry as gone.
     */
    private fun pruneWaitingSenders() {
        val current = _waitingSenders.value
        if (current.isEmpty()) return
        val holding = HashSet<String>()
        inbound.values.forEach { holding.add(it.fromUserId) }
        ctx?.let { holding.addAll(MapInboundKeyStore.senders(it)) }
        val next = current.filterTo(HashSet()) { holding.contains(it) }
        if (next.size == current.size) return
        _waitingSenders.value = next
        persist()
    }

    /**
     * Sign-out wipe. Ordering mirrors SessionTeardown: stop emitting FIRST, then clear the
     * in-memory state, then the prefs — otherwise a live provider callback could flush stale
     * presence back to disk after the delete.
     */
    fun resetForSignOut(context: Context) {
        provider?.stop()
        wantsVisible = false
        _visibility.value = MapVisibility.GHOST
        _ghostUntil.value = 0L
        _audience.value = emptyList()
        _subjects.value = emptyMap()
        _waitingSenders.value = emptySet()
        _onboarded.value = false
        _lastError.value = null
        shareId = null
        shareKey = null
        expiresAt = 0L
        seq = 0L
        inbound.clear()
        subjectSeq.clear()
        runCatching { SecurePrefs.open(context.applicationContext, "voiid_map").edit().clear().apply() }
        // The background-capture key store is a SEPARATE prefs file and must be cleared too,
        // or contacts' inbound map keys outlive the account that received them.
        runCatching { MapInboundKeyStore.clear(context.applicationContext) }
    }

    // ---- persistence (encrypted prefs, never SQLite) ------------------------------------

    private fun prefs() = ctx?.let { SecurePrefs.open(it, "voiid_map") }

    private fun persist() {
        val p = prefs() ?: return
        val inboundJson = ApiClient.json.encodeToString(
            ListSerializer(PersistedInbound.serializer()),
            inbound.map { (id, s) -> PersistedInbound(id, s.fromUserId, Base64.encodeToString(s.key, Base64.NO_WRAP), s.expiresAt) },
        )
        val audienceJson = ApiClient.json.encodeToString(ListSerializer(MapContact.serializer()), _audience.value)
        p.edit()
            .putString("visibility", _visibility.value.name)
            .putLong("ghost_until", _ghostUntil.value)
            .putBoolean("onboarded", _onboarded.value)
            .putString("audience", audienceJson)
            .putString("share_id", shareId)
            .putString("share_key", shareKey?.let { Base64.encodeToString(it, Base64.NO_WRAP) })
            .putLong("expires_at", expiresAt)
            .putString("inbound", inboundJson)
            // Persisted so a contact who is sharing with us still shows on the map after a
            // cold start, rather than vanishing until their next fix arrives.
            .putStringSet("waiting_senders", _waitingSenders.value)
            .apply()
    }

    private fun restore() {
        val p = prefs() ?: return
        _visibility.value = runCatching { MapVisibility.valueOf(p.getString("visibility", null) ?: "GHOST") }.getOrDefault(MapVisibility.GHOST)
        // A restored VISIBLE state means the user had asked to be visible, so the intent must
        // survive the restart too — otherwise onForeground() would never re-open the share.
        wantsVisible = _visibility.value == MapVisibility.VISIBLE
        _ghostUntil.value = p.getLong("ghost_until", 0L)
        _onboarded.value = p.getBoolean("onboarded", false)
        p.getString("audience", null)?.let { j ->
            _audience.value = runCatching { ApiClient.json.decodeFromString(ListSerializer(MapContact.serializer()), j) }.getOrDefault(emptyList())
        }
        shareId = p.getString("share_id", null)
        shareKey = p.getString("share_key", null)?.let { runCatching { Base64.decode(it, Base64.NO_WRAP) }.getOrNull() }
        expiresAt = p.getLong("expires_at", 0L)
        // Copy the set — SharedPreferences forbids mutating the instance it hands back.
        _waitingSenders.value = p.getStringSet("waiting_senders", null)?.toSet() ?: emptySet()
        p.getString("inbound", null)?.let { j ->
            runCatching { ApiClient.json.decodeFromString(ListSerializer(PersistedInbound.serializer()), j) }.getOrNull()?.forEach {
                inbound[it.shareId] = InboundShare(it.from, runCatching { Base64.decode(it.key, Base64.NO_WRAP) }.getOrNull() ?: return@forEach, it.expiresAt)
            }
        }
    }

    private fun now() = System.currentTimeMillis()
}

package com.voiid.app.net

/**
 * The ONE integration seam between the shared transports (the WS relay + ChatEngine's message
 * decode) and the location engines that consume them — docs/LOCATION.md.
 *
 * WHY a seam and not direct callbacks on WebSocketClient/ChatEngine: two engines subscribe to
 * the same frames — Feature (A) in-conversation sharing and Feature (B) the Map — and they are
 * built by different agents. A single mutable callback on WebSocketClient would let one clobber
 * the other. A subscriber LIST lets both coexist, and keeps the shared-file edits to a single
 * fan-out call rather than per-feature branching inside ChatEngine.
 *
 * Everything crossing this seam is OPAQUE to the transport:
 *   - [dispatchFix] / [dispatchStop] carry a base64 ciphertext blob the WS process copied
 *     verbatim and never parsed (a position, encrypted under a shareKey the server never holds).
 *   - [dispatchControl] carries the DECRYPTED plaintext of a durable `_vloc` message that
 *     already came off the Double Ratchet inside ChatEngine — so it is E2E, not server-visible.
 *
 * A subscriber MUST discard any fix whose share_id it does not recognise: the WS process has no
 * DB and cannot authorise recipients (§9 stated gap), so the receiving client is the actual
 * authorization. An unknown share_id decrypts to garbage under a key we do not hold anyway.
 */
object LocationRelay {

    /** Inbound streamed position fix (WS `loc_update`). ciphertext is base64, opaque. */
    fun interface FixSink { fun onFix(shareId: String, fromUserId: String, ciphertextB64: String, ts: Long) }

    /** Inbound instant stop (WS `loc_stop`), or a server-published revocation signal. */
    fun interface StopSink { fun onStop(shareId: String, fromUserId: String) }

    /**
     * Inbound DURABLE control message (`_vloc` plaintext off the ratchet): map_key / map_off,
     * and — for Feature (A) — live_start / live_stop / live_rekey / pin. Every subscriber filters
     * by the envelope's `k` and ignores kinds it does not own, so Feature (A)'s conversation
     * engine and the Map engine coexist on this one seam. [conversationId] is the 1:1 conversation
     * (or the group) it arrived on. A RENDERABLE kind is turned into a chat bubble by the
     * subscribed engine (ChatEngine.storeLocationInbound); a SILENT kind is consumed only.
     */
    fun interface ControlSink { fun onControl(plaintextJson: String, fromUserId: String, conversationId: String) }

    // CopyOnWrite semantics via synchronized snapshots — subscribers register once at engine
    // init and the dispatch path runs on the WS/Chat threads.
    private val fixSinks = mutableListOf<FixSink>()
    private val stopSinks = mutableListOf<StopSink>()
    private val controlSinks = mutableListOf<ControlSink>()

    fun subscribeFix(s: FixSink) = synchronized(fixSinks) { if (!fixSinks.contains(s)) fixSinks.add(s) }
    fun subscribeStop(s: StopSink) = synchronized(stopSinks) { if (!stopSinks.contains(s)) stopSinks.add(s) }
    fun subscribeControl(s: ControlSink) = synchronized(controlSinks) { if (!controlSinks.contains(s)) controlSinks.add(s) }

    fun dispatchFix(shareId: String, fromUserId: String, ciphertextB64: String, ts: Long) {
        val snapshot = synchronized(fixSinks) { fixSinks.toList() }
        for (s in snapshot) runCatching { s.onFix(shareId, fromUserId, ciphertextB64, ts) }
    }

    fun dispatchStop(shareId: String, fromUserId: String) {
        val snapshot = synchronized(stopSinks) { stopSinks.toList() }
        for (s in snapshot) runCatching { s.onStop(shareId, fromUserId) }
    }

    fun dispatchControl(plaintextJson: String, fromUserId: String, conversationId: String) {
        val snapshot = synchronized(controlSinks) { controlSinks.toList() }
        for (s in snapshot) runCatching { s.onControl(plaintextJson, fromUserId, conversationId) }
    }

    /**
     * Cheap pre-check ChatEngine uses to decide whether a decrypted plaintext is a location
     * control envelope worth routing here (rather than rendering as a chat bubble). Matches the
     * discriminator without a full JSON parse. The authoritative parse happens in the engine.
     */
    fun looksLikeEnvelope(plaintext: String): Boolean =
        plaintext.length < 4096 && plaintext.contains("\"_vloc\"")
}

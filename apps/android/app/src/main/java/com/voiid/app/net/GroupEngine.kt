package com.voiid.app.net

import android.content.Context
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import uniffi.voiid.GroupMember
import uniffi.voiid.GroupSession

/**
 * Real E2EE GROUP messaging on MLS (RFC 9420), on top of the e2e-core FFI + backend.
 * Companion to [ChatEngine] (which handles 1:1). One instance per app.
 *
 * ## Device model
 * There is exactly ONE MLS [GroupMember] per DEVICE (not per user, not per group). Its
 * stable identity label is `"<userId>::<deviceId>"`. The member object holds the signer,
 * this device's KeyPackage private keys, and the state of EVERY group the device is in.
 *
 * ## Persistence (the #1 correctness risk)
 * MLS state is IN-MEMORY only. We therefore [serialize] the member blob (Base64) into the
 * `voiid_mls` [SecurePrefs] store after EVERY state-changing FFI call — create, join, add,
 * remove, encrypt AND decrypt (each advances a ratchet) — and [restore] it on launch. We
 * also persist a `conversationId -> group_id` map so a group can be re-opened via
 * [GroupMember.loadGroup] after a restart.
 *
 * ## Transport
 *  - App messages: `session.encrypt` → ONE ciphertext, fanned out (same bytes) to every
 *    member device (excluding this one) over the existing 1:1 `messages/send` relay with
 *    `content_type="group"`. Received via `messages/conversation/:id` → `session.decrypt`.
 *  - Welcome / Commit: over `/mls/group-events` (NOT messages/send). Processed BEFORE app
 *    messages on every sync.
 *
 * ## Single-committer limitation
 * We use the single-committer model: the creator/admin issues commits and merges them
 * locally. Concurrent membership changes from two devices can fork group state; this is a
 * known limitation of this increment.
 */
class GroupEngine private constructor(context: Context) {

    companion object {
        @Volatile private var instance: GroupEngine? = null
        fun get(context: Context): GroupEngine =
            instance ?: synchronized(this) {
                instance ?: GroupEngine(context.applicationContext).also { instance = it }
            }

        /** How many KeyPackages to publish per batch (each is consumed by one add). */
        private const val KEYPACKAGE_LOW_WATER = 4
        private const val KEYPACKAGE_BATCH = 10
        private const val PREF_MEMBER = "member_blob"
        private const val PREF_GROUPMAP = "group_map"
        private const val PREF_KP_PUBLISHED = "kp_published_v1"
    }

    private val appContext = context.applicationContext
    private val tokens = TokenStore.get(appContext)
    private val api = ApiClient(tokens)
    private val e2e = E2EManager.get(appContext)
    private val chat = ChatEngine.get(appContext)
    private val prefs = SecurePrefs.open(appContext, "voiid_mls")

    /** Guards ALL access to the single mutable [member] handle + its persistence, so a
     *  4s poll and a WS/FCM push can't mutate MLS state concurrently and corrupt it. */
    private val lock = Mutex()

    /** The device MLS member (in-memory; the source of truth is the persisted blob). */
    private var member: GroupMember? = null

    /** conversationId -> MLS group_id (persisted so groups survive a restart). */
    private val groupIds = HashMap<String, ByteArray>()
    @Volatile private var groupMapLoaded = false

    /**
     * Fires the conversationId whenever an applied/merged commit advances that group's MLS
     * epoch, i.e. the exporter secret — and thus the derived group-call media key — changed.
     * A live [GroupCallManager] collects this to re-derive and re-apply the LiveKit E2EE key,
     * closing the epoch-skew gap where members at different epochs derive different keys and
     * can no longer decrypt each other's media. Buffered + [tryEmit] so emission never blocks
     * the MLS lock and a burst of commits can't suspend a state-changing FFI call. Only emitted
     * when the derived key genuinely changed (see [signalEpochAdvancedLocked]).
     */
    private val _epochChanges = MutableSharedFlow<String>(extraBufferCapacity = 64)
    val epochChanges: SharedFlow<String> = _epochChanges.asSharedFlow()

    /** conversationId -> last derived call-key Base64 (epoch fingerprint). Guarded by [lock]. */
    private val lastCallKeyByConv = HashMap<String, String>()

    /**
     * Sign-out teardown only (see [SessionTeardown]). Without this, [member] and the
     * [groupMapLoaded] latch stay populated in memory, so the NEXT account signed in on
     * this device would silently reuse the previous account's MLS device identity and
     * group map — the same bug class fixed for [E2EManager] above. Wipes the persisted
     * member blob, group map and KeyPackage-published flag too, so a restart can't
     * resurrect them either.
     */
    fun resetForSignOut() {
        member = null
        groupIds.clear()
        groupMapLoaded = false
        lastCallKeyByConv.clear()
        prefs.edit().clear().apply()
    }

    // MARK: - Member lifecycle

    /** This device's stable MLS identity label bytes: `"<userId>::<deviceId>"`. */
    private fun identityLabel(): ByteArray {
        val userId = tokens.userId ?: throw ApiError.NotAuthenticated
        val deviceId = e2e.deviceId ?: throw ApiError.Http(0, "device not registered yet")
        return "$userId::$deviceId".toByteArray()
    }

    /** Create-or-restore the device member (idempotent). MUST be called under [lock]. */
    private fun ensureMemberLocked(): GroupMember {
        member?.let { return it }
        loadGroupMap()
        val blob = prefs.getString(PREF_MEMBER, null)
        if (blob != null) {
            runCatching { GroupMember.restore(Base64.decode(blob, Base64.NO_WRAP)) }
                .onSuccess { member = it; Log.i("VOIID", "MLS: restored device member"); return it }
                .onFailure { Log.e("VOIID", "MLS: member restore failed — recreating", it) }
        }
        val m = GroupMember.create(identityLabel())
        member = m
        persistMemberLocked(m)
        // A brand-new member has no published KeyPackages — force a (re)publish next bootstrap.
        prefs.edit().remove(PREF_KP_PUBLISHED).apply()
        Log.i("VOIID", "MLS: created new device member")
        return m
    }

    private fun persistMemberLocked(m: GroupMember) {
        runCatching {
            prefs.edit().putString(PREF_MEMBER, Base64.encodeToString(m.serialize(), Base64.NO_WRAP)).apply()
        }.onFailure { Log.e("VOIID", "MLS: persist member failed", it) }
    }

    // MARK: - group_id map persistence

    private fun loadGroupMap() {
        if (groupMapLoaded) return
        groupMapLoaded = true
        val raw = prefs.getString(PREF_GROUPMAP, null) ?: return
        runCatching {
            ApiClient.json.decodeFromString(MapSerializer(String.serializer(), String.serializer()), raw)
                .forEach { (cid, b64) -> groupIds[cid] = Base64.decode(b64, Base64.NO_WRAP) }
        }.onFailure { Log.e("VOIID", "MLS: group map load failed", it) }
    }

    private fun persistGroupMapLocked() {
        val map = groupIds.mapValues { Base64.encodeToString(it.value, Base64.NO_WRAP) }
        runCatching {
            prefs.edit().putString(PREF_GROUPMAP,
                ApiClient.json.encodeToString(MapSerializer(String.serializer(), String.serializer()), map)).apply()
        }.onFailure { Log.e("VOIID", "MLS: group map persist failed", it) }
    }

    /** True if we have an MLS group for this conversation (locally joined/created). */
    fun hasGroup(conversationId: String): Boolean {
        loadGroupMap(); return groupIds.containsKey(conversationId)
    }

    // MARK: - Bootstrap (from E2EManager.bootstrap)

    /** Ensure the device member exists and its KeyPackages are published. Safe to call
     *  repeatedly; never throws (logged + swallowed) so it can't break 1:1 bootstrap. */
    suspend fun bootstrap() = withContext(Dispatchers.IO) {
        runCatching {
            lock.withLock<Unit> {
                val m = ensureMemberLocked()
                if (prefs.getString(PREF_KP_PUBLISHED, null) == null) {
                    publishKeyPackagesLocked(m)
                    prefs.edit().putString(PREF_KP_PUBLISHED, "1").apply()
                } else {
                    // THE ALREADY-BOOTSTRAPPED CASE IS THE ONE THAT NEEDED WORK. The batch
                    // published on first run is consumed one package at a time as people add
                    // this device to groups, and nothing replenished it — so a long-lived
                    // device eventually ran dry and OTHER people silently failed to add it,
                    // while this device saw nothing wrong at all.
                    topUpKeyPackagesIfLowLocked(m)
                }
            }
        }.onFailure { Log.e("VOIID", "MLS: bootstrap failed", it) }
        Unit
    }

    /** Generate + upload a fresh batch of this device's public KeyPackages. Each call to
     *  [GroupMember.keyPackage] yields a distinct package whose private half lives in the
     *  member blob, so we persist the member AFTER generating them. Caller holds [lock]. */
    private suspend fun publishKeyPackagesLocked(m: GroupMember) {
        val deviceId = e2e.deviceId ?: return
        val packages = (0 until KEYPACKAGE_BATCH).map { Base64.encodeToString(m.keyPackage(), Base64.NO_WRAP) }
        persistMemberLocked(m)   // persist BEFORE upload so private halves are never lost
        val body = ApiClient.json.encodeToString(
            UploadKeyPackagesBody.serializer(), UploadKeyPackagesBody(deviceId, packages))
        api.request("POST", "mls/keypackages", jsonBody = body)
        Log.i("VOIID", "MLS: published ${packages.size} key packages")
    }

    @Serializable
    private data class KeyPackageCountResponse(val available: Int = 0)

    /**
     * Republish when this device is running low. Mirrors the one-time-prekey top-up, and
     * exists for the same reason: the cost of running out lands on OTHER people (they cannot
     * add you to a group), never on the device that ran out.
     *
     * Best-effort throughout — a device that cannot top up right now is no worse off than
     * before the check, and surfacing it would put an error in front of a user who did
     * nothing and can do nothing about it.
     */
    private suspend fun topUpKeyPackagesIfLowLocked(m: GroupMember) {
        val deviceId = e2e.deviceId ?: return
        runCatching {
            val res: KeyPackageCountResponse =
                api.requestAs("GET", "mls/keypackages/count?device_id=$deviceId")
            if (res.available < KEYPACKAGE_LOW_WATER) {
                publishKeyPackagesLocked(m)
                Log.i("VOIID", "MLS: topped up key packages (had ${res.available})")
            }
        }.onFailure { Log.w("VOIID", "MLS: key-package top-up skipped", it) }
    }

    // MARK: - Create group

    /**
     * Build the MLS group for an already-created group conversation: create the group with
     * just us, then add every member (each of their devices) — distributing Welcome to the
     * new member and Commit to already-added members over /mls/group-events.
     */
    suspend fun createGroup(conversationId: String, memberUserIds: List<String>) = withContext(Dispatchers.IO) {
        lock.withLock<Unit> {
            val m = ensureMemberLocked()
            val session = m.createGroup()
            groupIds[conversationId] = session.groupId()
            persistGroupMapLocked()
            persistMemberLocked(m)
            Log.i("VOIID", "MLS: created group conv=$conversationId")
            // Members already welcomed (so their sessions must receive later commits). We
            // start with just ourselves.
            val welcomed = mutableSetOf(tokens.userId ?: "")
            val toAdd = memberUserIds.distinct().filter { it.isNotBlank() && it != tokens.userId }
            for (uid in toAdd) {
                runCatching { addUserToGroupLocked(conversationId, session, m, uid, welcomed) }
                    .onFailure { Log.e("VOIID", "MLS: add member $uid failed", it) }
                welcomed.add(uid)
            }
        }
    }

    // MARK: - Add / remove member (admin ops)

    /** Add a user (all their active devices) to an existing group. Caller need not hold the
     *  lock — this acquires it. */
    suspend fun addMember(conversationId: String, userId: String) = withContext(Dispatchers.IO) {
        lock.withLock<Unit> {
            val m = ensureMemberLocked()
            val gid = groupIds[conversationId] ?: run {
                Log.w("VOIID", "MLS: addMember — no local group for conv=$conversationId"); return@withLock
            }
            val session = m.loadGroup(gid)
            // Snapshot the roster BEFORE adding, so the Commit fan-out targets the members
            // who were already there and not the new joiner (who gets a Welcome instead).
            val existing = currentMemberUserIds(conversationId).toMutableSet()

            // ── SERVER ROSTER FIRST, BEFORE THE WELCOME ──────────────────────────────
            // The MLS group and the server's conversation roster are two different lists and
            // this engine used to update only the first. A member added after group creation
            // was absent from the roster the server fans messages out to — so they held a
            // working MLS group and received nothing through it, and `POST /calls/group/token`
            // 403'd them out of their own group's calls.
            //
            // It runs BEFORE the Welcome deliberately: if the roster write fails we stop and
            // no Welcome goes out, leaving the person simply not-yet-added. The reverse order
            // would hand them group keys and then leave them unreachable — a silently broken
            // member rather than an obviously absent one.
            //
            // Idempotent server-side, so retrying after a partial failure is safe.
            val rostered = runCatching { addToServerRoster(conversationId, userId) }
            if (rostered.isFailure) {
                Log.e("VOIID", "MLS: addMember $userId — server roster write failed, not "
                    + "distributing a Welcome", rostered.exceptionOrNull())
                return@withLock
            }

            runCatching { addUserToGroupLocked(conversationId, session, m, userId, existing) }
                .onFailure { Log.e("VOIID", "MLS: addMember $userId failed", it) }
        }
    }

    /** Fetch [userId]'s KeyPackages (one per device), add each to the group, then relay the
     *  Welcome to the new user and the Commit to everyone in [welcomed]. Caller holds [lock]. */
    private suspend fun addUserToGroupLocked(
        conversationId: String, session: GroupSession, m: GroupMember,
        userId: String, welcomed: Set<String>,
    ) {
        val kps: KeyPackagesResponse = api.requestAs("GET", "mls/keypackages/$userId")
        if (kps.key_packages.isEmpty()) {
            Log.w("VOIID", "MLS: user $userId has no key packages — skipping"); return
        }
        for (kp in kps.key_packages) {
            val out = session.addMember(m, Base64.decode(kp.key_package, Base64.NO_WRAP))
            persistMemberLocked(m)   // addMember merged the commit locally → state changed
            val events = mutableListOf<GroupEvent>()
            // Welcome → the newly added user (this device's copy).
            events.add(GroupEvent(
                recipient_user_id = userId,
                kind = "welcome",
                payload = Base64.encodeToString(out.welcome, Base64.NO_WRAP),
                ratchet_tree = Base64.encodeToString(out.ratchetTree, Base64.NO_WRAP),
            ))
            // Commit → every member already in the group (so their epoch advances).
            welcomed.filter { it.isNotBlank() && it != tokens.userId && it != userId }.forEach { existing ->
                events.add(GroupEvent(
                    recipient_user_id = existing,
                    kind = "commit",
                    payload = Base64.encodeToString(out.commit, Base64.NO_WRAP),
                ))
            }
            postGroupEvents(conversationId, events)
        }
        // Each addMember merged a commit locally → epoch advanced. Re-key any live call.
        signalEpochAdvancedLocked(conversationId, session, m)
        Log.i("VOIID", "MLS: added user=$userId (${kps.key_packages.size} devices) to conv=$conversationId")
    }

    /** Remove a user (all their devices) from the group and broadcast the rekey commit to
     *  the remaining members. */
    suspend fun removeMember(conversationId: String, userId: String) = withContext(Dispatchers.IO) {
        lock.withLock<Unit> {
            val m = ensureMemberLocked()
            val gid = groupIds[conversationId] ?: return@withLock
            val session = m.loadGroup(gid)
            val remaining = currentMemberUserIds(conversationId).filter { it != userId && it != tokens.userId }
            val devices: DevicesResponse = runCatching { api.requestAs<DevicesResponse>("GET", "devices/$userId") }
                .getOrElse { Log.e("VOIID", "MLS: remove — devices lookup failed", it); return@withLock }
            for (d in devices.devices) {
                val identity = "$userId::${d.id}".toByteArray()
                val commit = runCatching { session.removeMember(m, identity) }.getOrNull()
                if (commit != null) {
                    persistMemberLocked(m)
                    val events = remaining.filter { it.isNotBlank() }.map {
                        GroupEvent(it, "commit", Base64.encodeToString(commit, Base64.NO_WRAP))
                    }
                    if (events.isNotEmpty()) postGroupEvents(conversationId, events)
                } else {
                    Log.w("VOIID", "MLS: removeMember device=${d.id} failed (maybe not a member)")
                }
            }
            // Removal rekeys the group → epoch advanced. Re-key any live call.
            signalEpochAdvancedLocked(conversationId, session, m)

            // ── SERVER ROSTER LAST, AFTER THE REMOVAL COMMIT ─────────────────────────
            // Mirror image of the add, and the ordering is just as deliberate. The MLS rekey
            // stops the removed member decrypting anything AFTER this commit, but the server
            // was still fanning ciphertext to them and still minting them call tokens,
            // because nothing ever took them off the roster.
            //
            // It runs AFTER the commit is broadcast so the remaining members are guaranteed
            // to have received it: dropping the roster first would stop the server delivering
            // to the very people who still need this commit.
            runCatching { removeFromServerRoster(conversationId, userId) }
                .onFailure { Log.e("VOIID", "MLS: removed $userId from the group but the "
                    + "server roster write failed — they may still receive ciphertext", it) }

            Log.i("VOIID", "MLS: removed user=$userId from conv=$conversationId")
        }
    }

    // ── Server conversation roster ──────────────────────────────────────────────────
    //
    // The server roster decides who message fan-out reaches and who may mint a group call
    // token. It is SEPARATE from MLS membership, and keeping the two in step is this engine's
    // job — MLS decides who can DECRYPT, the roster decides who is DELIVERED TO. Neither is
    // sufficient alone: MLS without the roster is a member who receives nothing, and the
    // roster without MLS is a member who receives bytes they cannot read.

    @Serializable private data class AddMembersBody(val user_ids: List<String>)

    private suspend fun addToServerRoster(conversationId: String, userId: String) {
        api.request(
            "POST", "conversations/$conversationId/members",
            jsonBody = ApiClient.json.encodeToString(
                AddMembersBody.serializer(), AddMembersBody(listOf(userId))),
        )
    }

    private suspend fun removeFromServerRoster(conversationId: String, userId: String) {
        api.request("DELETE", "conversations/$conversationId/members/$userId")
    }

    /** Best-effort current member user ids of the conversation (server truth). */
    private suspend fun currentMemberUserIds(conversationId: String): List<String> =
        runCatching {
            val env: ConvMembersResponse = api.requestAs("GET", "conversations/$conversationId")
            env.members.map { it.user_id }
        }.getOrDefault(emptyList())

    // MARK: - Send app message

    /** Encrypt [text] once via MLS and fan the SAME ciphertext out to every member device
     *  (excluding this one). Stores a local echo so the sender sees it immediately. */
    suspend fun sendGroupMessage(conversationId: String, text: String) = withContext(Dispatchers.IO) {
        // Store the echo up-front so it shows instantly even if the send races.
        chat.storeGroupOutgoing(conversationId, text)
        lock.withLock<Unit> {
            val m = ensureMemberLocked()
            val gid = groupIds[conversationId] ?: run {
                Log.w("VOIID", "MLS: send — no local group for conv=$conversationId"); return@withLock
            }
            val session = m.loadGroup(gid)
            val ciphertext = session.encrypt(m, text.toByteArray())
            persistMemberLocked(m)   // encrypt advanced the ratchet → state changed
            val ctB64 = Base64.encodeToString(ciphertext, Base64.NO_WRAP)
            val targets = resolveGroupTargetDevices(conversationId)
            if (targets.isEmpty()) { Log.w("VOIID", "MLS: send — no target devices"); return@withLock }
            val bundle = targets.map { DeviceCiphertext(it.deviceId, ctB64) }
            val body = ApiClient.json.encodeToString(
                SendBundleBody.serializer(),
                SendBundleBody(conversationId, e2e.deviceId, bundle, content_type = "group"))
            runCatching { api.request("POST", "messages/send", jsonBody = body) }
                .onSuccess { Log.i("VOIID", "MLS: sent group msg conv=$conversationId devices=${bundle.size}") }
                .onFailure { Log.e("VOIID", "MLS: group send failed", it) }
        }
    }

    /**
     * Send a location-protocol control envelope (docs/LOCATION.md P2 — live_start / live_stop /
     * live_rekey) into a GROUP over MLS. Same fan-out as [sendGroupMessage] but with NO local
     * echo (the location engine owns the sender's own bubble) and no bubble on receipt: the
     * `_vloc` plaintext is intercepted in [receiveGroupMessages] and handed to [LocationRelay].
     * [envelopeJson] carries the shareKey for a live_start and never leaves E2E.
     */
    suspend fun sendGroupLocationControl(conversationId: String, envelopeJson: String) = withContext(Dispatchers.IO) {
        lock.withLock<Unit> {
            val m = ensureMemberLocked()
            val gid = groupIds[conversationId] ?: run {
                Log.w("VOIID", "MLS: location send — no local group for conv=$conversationId"); return@withLock
            }
            val session = m.loadGroup(gid)
            val ciphertext = session.encrypt(m, envelopeJson.toByteArray())
            persistMemberLocked(m)   // encrypt advanced the ratchet → state changed
            val ctB64 = Base64.encodeToString(ciphertext, Base64.NO_WRAP)
            val targets = resolveGroupTargetDevices(conversationId)
            if (targets.isEmpty()) { Log.w("VOIID", "MLS: location send — no target devices"); return@withLock }
            val bundle = targets.map { DeviceCiphertext(it.deviceId, ctB64) }
            val body = ApiClient.json.encodeToString(
                SendBundleBody.serializer(),
                SendBundleBody(conversationId, e2e.deviceId, bundle, content_type = "group"))
            runCatching { api.request("POST", "messages/send", jsonBody = body) }
                .onFailure { Log.e("VOIID", "MLS: group location send failed", it) }
        }
    }

    private data class TargetDevice(val userId: String, val deviceId: String)

    /** Every member device of the conversation EXCEPT this sending device. */
    private suspend fun resolveGroupTargetDevices(conversationId: String): List<TargetDevice> {
        val myDev = e2e.deviceId
        val out = mutableListOf<TargetDevice>()
        for (uid in currentMemberUserIds(conversationId)) {
            val devs: DevicesResponse? = runCatching { api.requestAs<DevicesResponse>("GET", "devices/$uid") }.getOrNull()
            devs?.devices?.forEach { d -> if (d.id != myDev) out.add(TargetDevice(uid, d.id)) }
        }
        return out
    }

    // MARK: - Receive: group events (welcome/commit) — process BEFORE app messages

    /** Fetch + apply this device's undelivered Welcome/Commit events. Never throws. */
    suspend fun syncGroupEvents() = withContext(Dispatchers.IO) {
        lock.withLock<Unit> {
            val m = ensureMemberLocked()
            val env: GroupEventsResponse = runCatching { api.requestAs<GroupEventsResponse>("GET", "mls/group-events") }
                .getOrElse { Log.w("VOIID", "MLS: group-events fetch failed: ${it.message}"); return@withLock }
            if (env.events.isEmpty()) return@withLock
            // Welcomes first (so a same-batch commit for a just-joined group can be applied).
            val ordered = env.events.sortedWith(compareBy({ if (it.kind == "welcome") 0 else 1 }, { it.created_at ?: "" }))
            for (ev in ordered) {
                runCatching {
                    when (ev.kind) {
                        "welcome" -> applyWelcomeLocked(m, ev)
                        "commit" -> applyCommitLocked(m, ev)
                        else -> Log.w("VOIID", "MLS: unknown group event kind=${ev.kind}")
                    }
                }.onFailure { Log.e("VOIID", "MLS: apply ${ev.kind} for conv=${ev.conversation_id} failed", it) }
            }
        }
    }

    private fun applyWelcomeLocked(m: GroupMember, ev: GroupEventDTO) {
        val ratchetTree = ev.ratchet_tree?.let { Base64.decode(it, Base64.NO_WRAP) }
            ?: run { Log.w("VOIID", "MLS: welcome missing ratchet_tree"); return }
        // Already joined this conversation? A duplicate welcome would fork state — skip.
        if (groupIds.containsKey(ev.conversation_id)) { Log.i("VOIID", "MLS: welcome for known group — skip"); return }
        val session = m.joinGroup(Base64.decode(ev.payload, Base64.NO_WRAP), ratchetTree)
        groupIds[ev.conversation_id] = session.groupId()
        persistGroupMapLocked()
        persistMemberLocked(m)
        Log.i("VOIID", "MLS: joined group via welcome conv=${ev.conversation_id}")
    }

    private fun applyCommitLocked(m: GroupMember, ev: GroupEventDTO) {
        val gid = groupIds[ev.conversation_id] ?: run {
            Log.w("VOIID", "MLS: commit for unknown group conv=${ev.conversation_id} — skip"); return
        }
        val session = m.loadGroup(gid)
        session.decrypt(m, Base64.decode(ev.payload, Base64.NO_WRAP))   // applies commit, returns null
        persistMemberLocked(m)
        // The commit advanced our epoch → the call key changed. Re-key any live call.
        signalEpochAdvancedLocked(ev.conversation_id, session, m)
        Log.i("VOIID", "MLS: applied commit conv=${ev.conversation_id}")
    }

    // MARK: - Receive: app messages

    /** Fetch this device's pending group ciphertext for a conversation, decrypt each new
     *  one exactly once, and persist plaintext into the shared ChatEngine store. */
    suspend fun receiveGroupMessages(conversationId: String) = withContext(Dispatchers.IO) {
        lock.withLock<Unit> {
            val m = ensureMemberLocked()
            val gid = groupIds[conversationId] ?: return@withLock
            val myId = tokens.userId
            val devParam = e2e.deviceId?.let { "?device_id=$it" } ?: ""
            val env: MessagesResponse = runCatching {
                api.requestAs<MessagesResponse>("GET", "messages/conversation/$conversationId$devParam")
            }.getOrElse { Log.w("VOIID", "MLS: fetch group msgs failed: ${it.message}"); return@withLock }
            val session = m.loadGroup(gid)
            // Only NEW inbound group ciphertext (decrypt-once; skip our own echoes).
            val fresh = env.messages.asReversed().filter {           // server DESC → process ASC
                it.content_type == "group" && it.sender_id != myId && !chat.hasMessage(conversationId, it.id)
            }
            for (msg in fresh) {
                // A null ciphertext means the server had no per-device blob for us yet (our
                // device_id wasn't resolved when this row's fan-out was written, or delivery
                // to this device is still pending) — skip for now, don't tombstone it.
                val rawCiphertext = msg.ciphertext ?: continue
                val ct = runCatching { Base64.decode(rawCiphertext, Base64.NO_WRAP) }.getOrNull()
                val createdAt = parseIso(msg.created_at)
                if (ct == null) {
                    chat.storeGroupTombstone(conversationId, msg.id, msg.sender_id, createdAt)
                } else {
                    runCatching { session.decrypt(m, ct) }
                        .onSuccess { plain ->
                            persistMemberLocked(m)   // decrypt advanced the ratchet → state changed
                            if (plain != null) {
                                val text = plain.decodeToString()
                                // A location-protocol control envelope (docs/LOCATION.md P2) rides the
                                // MLS app channel just like text, tagged only by its `_vloc` marker
                                // (group content_type is always "group"). Route it to the location
                                // engine via the shared seam instead of a chat bubble; the engine
                                // renders the pin/live bubble itself.
                                if (LocationRelay.looksLikeEnvelope(text)) {
                                    LocationRelay.dispatchControl(text, msg.sender_id, conversationId)
                                } else {
                                    chat.storeGroupInbound(conversationId, msg.id, msg.sender_id, text, createdAt)
                                }
                                Log.i("VOIID", "MLS: decrypted group msg id=${msg.id}")
                            } // null = a commit rode the app channel; nothing to show
                        }
                        .onFailure {
                            persistMemberLocked(m)
                            Log.e("VOIID", "MLS: group decrypt FAILED id=${msg.id}", it)
                            // Tombstone so we don't re-decrypt a dead ratchet message forever.
                            chat.storeGroupTombstone(conversationId, msg.id, msg.sender_id, createdAt)
                        }
                }
            }
            // Report DELIVERED for everything we just took in, in one call rather than one
            // per message. Without this a group sender never left "Sent" until a read
            // happened to land — see ChatEngine.markGroupDelivered.
            //
            // Tombstoned messages are included on purpose: the ciphertext genuinely reached
            // this device, which is what `delivered` asserts. Only `read` requires a human,
            // and markRead excludes them separately.
            val received = fresh.map { it.id }
            if (received.isNotEmpty()) chat.markGroupDelivered(received)
        }
    }

    // MARK: - Group call key (LiveKit E2EE)

    /**
     * Derive the shared media key for a group CALL in this conversation, encoded for
     * LiveKit's key provider. Returns null if we have no MLS group for the conversation
     * (never joined / not synced yet) or the derivation fails.
     *
     * ## Derivation
     * `GroupSession.callKeys` returns [uniffi.voiid.SrtpKeys] (`masterKey` ‖ `masterSalt`)
     * derived from the MLS **exporter secret**, so:
     *  - every member at the same epoch derives byte-identical material, with no key
     *    exchange over the wire, and
     *  - it changes on every membership commit (add/remove rekeys the group).
     *
     * ## Why Base64
     * LiveKit's `KeyProvider.setSharedKey` takes a **String**, which it converts with
     * `toByteArray(UTF_8)` before handing it to the frame cryptor's HKDF. Raw MLS key bytes
     * are not valid UTF-8 — encoding them would be lossy (invalid sequences collapse to
     * U+FFFD) and could silently converge to the same bytes on different inputs. We
     * therefore Base64 (NO_WRAP, ASCII-safe) the concatenation, which round-trips through
     * UTF-8 unchanged and preserves the full entropy of the input through LiveKit's KDF.
     * This is an ENCODING, not a weakening: the key material is unchanged.
     *
     * The result never leaves the device — it is not sent to the API and never reaches the SFU.
     */
    suspend fun callKey(conversationId: String): String? = withContext(Dispatchers.IO) {
        lock.withLock<String?> {
            val m = runCatching { ensureMemberLocked() }.getOrElse {
                Log.e("VOIID", "MLS: callKey — no member", it); return@withLock null
            }
            val gid = groupIds[conversationId] ?: run {
                Log.w("VOIID", "MLS: callKey — no local group for conv=$conversationId"); return@withLock null
            }
            runCatching {
                val session = m.loadGroup(gid)
                val key = deriveCallKeyB64(session, m)
                // Seed the epoch fingerprint so a commit that lands DURING the call is detected
                // as a change and triggers exactly one re-key (not a spurious one at join).
                lastCallKeyByConv[conversationId] = key
                key
            }.getOrElse {
                Log.e("VOIID", "MLS: callKey derivation failed for conv=$conversationId", it); null
            }
        }
    }

    /**
     * Base64 (NO_WRAP) of `masterKey ‖ masterSalt` for a loaded [session] — the exact material
     * handed to LiveKit's key provider. Because it is derived from the MLS exporter secret it
     * also serves as an epoch fingerprint: it changes iff the epoch advanced. Caller holds [lock].
     */
    private fun deriveCallKeyB64(session: GroupSession, m: GroupMember): String {
        val keys = session.callKeys(m)
        return Base64.encodeToString(keys.masterKey + keys.masterSalt, Base64.NO_WRAP)
    }

    /**
     * Emit [conversationId] on [epochChanges] iff the derived call key genuinely changed since we
     * last saw it (call join seeds it; each commit updates it). Idempotent re-applies of the same
     * commit — or commits that don't move the exporter secret — do NOT wake a live call. Never
     * throws: a fingerprint failure just skips the signal, leaving the call on its current key.
     * Caller holds [lock].
     */
    private fun signalEpochAdvancedLocked(conversationId: String, session: GroupSession, m: GroupMember) {
        val fp = runCatching { deriveCallKeyB64(session, m) }.getOrElse {
            Log.w("VOIID", "MLS: epoch fingerprint failed conv=$conversationId — skip rekey signal", it); return
        }
        val prev = lastCallKeyByConv.put(conversationId, fp)
        if (prev != null && prev != fp) {
            val delivered = _epochChanges.tryEmit(conversationId)
            Log.i("VOIID", "MLS: epoch advanced conv=$conversationId rekey-signal delivered=$delivered")
        }
    }

    // MARK: - Helpers

    private suspend fun postGroupEvents(conversationId: String, events: List<GroupEvent>) {
        if (events.isEmpty()) return
        val body = ApiClient.json.encodeToString(
            PostGroupEventsBody.serializer(), PostGroupEventsBody(conversationId, events))
        api.request("POST", "mls/group-events", jsonBody = body)
    }

    private fun parseIso(s: String): Long =
        runCatching { java.time.Instant.parse(s).toEpochMilli() }.getOrDefault(System.currentTimeMillis())

    // MARK: - DTOs

    @Serializable private data class UploadKeyPackagesBody(val device_id: String, val key_packages: List<String>)
    @Serializable private data class KeyPackageDTO(val device_id: String, val key_package: String)
    @Serializable private data class KeyPackagesResponse(val key_packages: List<KeyPackageDTO> = emptyList())

    @Serializable private data class GroupEvent(
        val recipient_user_id: String,
        val kind: String,
        val payload: String,
        val ratchet_tree: String? = null,
    )
    @Serializable private data class PostGroupEventsBody(val conversation_id: String, val events: List<GroupEvent>)
    @Serializable private data class GroupEventDTO(
        val id: String? = null,
        val conversation_id: String,
        val sender_user_id: String? = null,
        val kind: String,
        val payload: String,
        val ratchet_tree: String? = null,
        val created_at: String? = null,
    )
    @Serializable private data class GroupEventsResponse(val events: List<GroupEventDTO> = emptyList())

    @Serializable private data class DeviceCiphertext(val recipient_device_id: String, val ciphertext: String)
    @Serializable private data class SendBundleBody(
        val conversation_id: String,
        val sender_device_id: String? = null,
        val messages: List<DeviceCiphertext>,
        val content_type: String? = null,
    )
    @Serializable private data class MessageDTO(
        val id: String,
        val sender_id: String,
        val ciphertext: String? = null,
        val created_at: String,
        val sender_device_id: String? = null,
        val content_type: String? = null,
    )
    @Serializable private data class MessagesResponse(val messages: List<MessageDTO> = emptyList())
    @Serializable private data class DeviceDTO(val id: String)
    @Serializable private data class DevicesResponse(val devices: List<DeviceDTO> = emptyList())
    @Serializable private data class ConvMemberDTO(val user_id: String)
    @Serializable private data class ConvMembersResponse(val members: List<ConvMemberDTO> = emptyList())
}

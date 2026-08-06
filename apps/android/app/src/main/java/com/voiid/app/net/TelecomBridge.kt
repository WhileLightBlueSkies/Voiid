package com.voiid.app.net

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import androidx.annotation.RequiresApi
import com.voiid.app.main.CallKind
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentHashMap

/**
 * The ONE place Android's Telecom stack is touched — the Android counterpart of iOS's
 * `CallManager` (the CallKit bridge), sitting alongside the WebRTC engine rather than
 * inside it.
 *
 * WHAT THIS BUYS (the WhatsApp behaviour):
 *  - Voiid calls appear in the system call log / dialer Recents, attributed to the right
 *    contact, because the [PhoneAccount] carries a `tel:` handle the OS can match to the
 *    address book itself.
 *  - The OS arbitrates between a Voiid call and a cellular call instead of the two
 *    fighting over the microphone.
 *  - Bluetooth headsets, Wear watches and Android Auto get answer/hang-up/route controls.
 *
 * WHAT IT DOES NOT BUY, and this is a real, unavoidable divergence from iOS:
 * self-managed calls are NOT written to the call log by default. The only pre-Android-16.1
 * opt-in is [PhoneAccount.EXTRA_LOG_SELF_MANAGED_CALLS] (API 30+), which works ONLY with a
 * `tel:`/`sip:` handle — which is why [E164] exists and why a peer with no number gets no
 * Recents row. That extra was deprecated in favour of the unified VoIP call log, which
 * needs the *dialer* to opt in too, so on some OEM ROMs nothing will appear in Recents no
 * matter what we do. There is no Android API that guarantees it.
 *
 * DESIGN RULE: Telecom is a pure OBSERVER of [CallManager]'s state machine. It never
 * becomes load-bearing. Every entry point here is wrapped, returns a boolean, and a
 * `false` means "carry on with the in-app path exactly as before" — a Telecom refusal
 * (missing permission, emergency call in progress, an OEM that disabled the account, a
 * registration that silently failed) must NEVER be able to prevent a call that works
 * today. Group calls ([GroupCallManager]) are deliberately never reported: a group call
 * has no single `tel:` handle and would corrupt both the call log and the one-call-at-a
 * -time invariant the engine relies on.
 */
object TelecomBridge {

    /** Stable id for our single self-managed account. Must not change across versions. */
    private const val ACCOUNT_ID = "voiid_self_managed"

    /**
     * Handle scheme for a peer we hold NO phone number for. The direct analogue of iOS's
     * `.generic` CXHandle: Telecom rejects a call with no address at all, so there must
     * always be something to pass — it just cannot be matched to a contact or logged.
     */
    private const val SCHEME_VOIID = "voiid"

    // Extras we thread through Telecom and read back in VoiidConnectionService. Telecom
    // hands the ConnectionRequest to a possibly-fresh process, so the connection is rebuilt
    // from these rather than from whatever CallManager happens to hold.
    const val EXTRA_CALL_ID = "com.voiid.app.telecom.CALL_ID"
    const val EXTRA_PEER_USER_ID = "com.voiid.app.telecom.PEER_USER_ID"
    const val EXTRA_PEER_NAME = "com.voiid.app.telecom.PEER_NAME"
    const val EXTRA_CONVERSATION_ID = "com.voiid.app.telecom.CONVERSATION_ID"
    const val EXTRA_VIDEO = "com.voiid.app.telecom.VIDEO"

    /** Why Telecom is or isn't carrying our calls. Surfaced so a refusal is visible, not silent. */
    enum class Availability {
        /** Android 7.x: self-managed ConnectionService needs API 26. In-app path only. */
        UNSUPPORTED_OS,

        /** Not registered yet (init hasn't run), or registration threw. */
        UNAVAILABLE,

        /** PhoneAccount registered; calls will be offered to Telecom. */
        READY,

        /** Registered, but Telecom refused the last call (emergency call, OEM policy, …). */
        REFUSED,
    }

    data class Status(val availability: Availability, val detail: String? = null)

    private val _status = MutableStateFlow(Status(Availability.UNAVAILABLE))

    /**
     * Observable so a diagnostics screen (or a log line) can say plainly whether system
     * call-log integration is live. Nothing in the call path reads this — it is reporting,
     * not control flow.
     */
    val status: StateFlow<Status> = _status.asStateFlow()

    @Volatile private var registered = false
    @Volatile private var accountHandle: PhoneAccountHandle? = null

    /**
     * call id -> live Connection. The engine drives state onto the Connection through here;
     * the Connection drives user actions back into the engine. Concurrent because Telecom
     * callbacks arrive on a binder thread while the engine runs on main/exec.
     */
    private val connections = ConcurrentHashMap<String, VoiidConnection>()

    // call_ids that were disconnected BEFORE Telecom finished binding their Connection.
    // placeCall/addNewIncomingCall are asynchronous, so a call can end (rejected fast, or
    // the caller cancels) in the window before onCreate*Connection fires. setDisconnected
    // then finds no entry and returns, and the Connection that arrives moments later is
    // never finished — a permanent phantom "ongoing call" in the system. attach() consults
    // this to finish such a Connection the instant it is created. Value = DisconnectCause.
    private val pendingDisconnects = ConcurrentHashMap<String, Int>()

    /** True while at least one call is genuinely owned by Telecom (gates the phoneCall FGS type). */
    val hasActiveConnection: Boolean get() = connections.isNotEmpty()

    // ---- registration ----------------------------------------------------------

    /**
     * Register the self-managed [PhoneAccount]. Idempotent; called from [CallManager.init],
     * so every entry point (Activity, FCM, service) has done it before a call can happen.
     *
     * A self-managed account needs NO user action in Settings — unlike a CALL_PROVIDER
     * account it is enabled on registration. Several OEM ROMs nevertheless list it somewhere
     * the user can switch off, and registration itself can throw, which is why the result is
     * recorded in [status] rather than assumed.
     */
    fun register(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            _status.value = Status(Availability.UNSUPPORTED_OS, "self-managed calls require Android 8.0")
            return
        }
        if (registered) return
        synchronized(this) {
            if (registered) return
            registerLocked(context.applicationContext)
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    @SuppressLint("MissingPermission")   // MANAGE_OWN_CALLS is a normal, install-time permission.
    private fun registerLocked(context: Context) {
        val tm = context.getSystemService(TelecomManager::class.java)
        if (tm == null) {
            _status.value = Status(Availability.UNAVAILABLE, "no TelecomManager on this device")
            return
        }
        val handle = PhoneAccountHandle(
            ComponentName(context, VoiidConnectionService::class.java),
            ACCOUNT_ID,
        )
        val extras = Bundle().apply {
            // THE opt-in that puts self-managed calls into the system call log before
            // Android 16.1. Deprecated in API 36.1 in favour of the unified VoIP call log
            // (see CallBackActivity), but it is the only mechanism that works on the phones
            // people actually own today, so we ship both.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                putBoolean(PhoneAccount.EXTRA_LOG_SELF_MANAGED_CALLS, true)
            }
        }
        val account = PhoneAccount.builder(handle, "Voiid")
            .setCapabilities(
                PhoneAccount.CAPABILITY_SELF_MANAGED or
                    PhoneAccount.CAPABILITY_SUPPORTS_VIDEO_CALLING or
                    PhoneAccount.CAPABILITY_VIDEO_CALLING,
            )
            // tel:/sip: are what make call-log logging legal at all; the private scheme is
            // the fallback for peers whose number we do not hold.
            .addSupportedUriScheme(PhoneAccount.SCHEME_TEL)
            .addSupportedUriScheme(PhoneAccount.SCHEME_SIP)
            .addSupportedUriScheme(SCHEME_VOIID)
            .setShortDescription("Voiid calls")
            .setExtras(extras)
            .build()

        val ok = runCatching { tm.registerPhoneAccount(account) }
        if (ok.isSuccess) {
            accountHandle = handle
            registered = true
            _status.value = Status(Availability.READY)
        } else {
            _status.value = Status(
                Availability.UNAVAILABLE,
                ok.exceptionOrNull()?.message ?: "registerPhoneAccount failed",
            )
        }
    }

    // ---- handles ---------------------------------------------------------------

    /**
     * The address Telecom (and therefore the call log) sees for a peer. Exact analogue of
     * iOS `CallManager.makeHandle`.
     *
     * Prefer the E.164 number: it is the ONLY value the OS can resolve to a contact, and the
     * only one the call log will accept for a self-managed call. Fall back to an opaque
     * `voiid:` handle when we have no number, which still produces a valid — if unlinked and
     * unlogged — call rather than a rejected report.
     *
     * PRIVACY CONSEQUENCE, deliberately accepted and identical to the iOS decision: a `tel:`
     * handle puts the peer's phone number into the system call log. That is exactly what
     * WhatsApp and Signal do and what "it shows up in my phone app" means, but it is a real
     * change from an opaque handle and deserves saying out loud.
     */
    fun makeHandle(phoneE164: String?, fallbackUserId: String): Uri {
        val e164 = E164.normalize(phoneE164)
        return if (e164 != null) Uri.fromParts(PhoneAccount.SCHEME_TEL, e164, null)
        else Uri.fromParts(SCHEME_VOIID, fallbackUserId, null)
    }

    // ---- reporting calls -------------------------------------------------------

    /**
     * Ask Telecom to own an outgoing call we have already started in-app.
     *
     * Returns false — and the caller simply carries on — when the OS is too old, the account
     * failed to register, or Telecom says no (an emergency call is up, or a managed call that
     * cannot be held is in progress). The in-app call is already running by this point; this
     * only decides whether the system also knows about it.
     */
    fun placeOutgoing(
        context: Context,
        callId: String,
        peerUserId: String,
        peerName: String,
        conversationId: String?,
        kind: CallKind,
        phoneE164: String?,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return placeOutgoingImpl(context, callId, peerUserId, peerName, conversationId, kind, phoneE164)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    @SuppressLint("MissingPermission")   // MANAGE_OWN_CALLS, declared in the manifest.
    private fun placeOutgoingImpl(
        context: Context,
        callId: String,
        peerUserId: String,
        peerName: String,
        conversationId: String?,
        kind: CallKind,
        phoneE164: String?,
    ): Boolean {
        val tm = context.getSystemService(TelecomManager::class.java) ?: return false
        val handle = accountHandle ?: return false
        val address = makeHandle(phoneE164, peerUserId)
        // SAFETY, and the worst failure mode in this whole file: `placeCall` with a `tel:` Uri
        // hands the call to the DEFAULT DIALER — i.e. places a REAL CELLULAR CALL, billed to
        // the user — if our PhoneAccountHandle is not honoured. Three guards stand in the way:
        //   1. `accountHandle` is only ever set after registerPhoneAccount returned;
        //   2. isOutgoingCallPermitted() is false for a handle Telecom does not hold as a
        //      registered self-managed account;
        //   3. on API 31+ we can read our own accounts back, the only positive confirmation
        //      the platform offers.
        // If any of them is unhappy we return false and the call proceeds in-app only.
        if (!runCatching { tm.isOutgoingCallPermitted(handle) }.getOrDefault(false)) {
            _status.value = Status(Availability.REFUSED, "isOutgoingCallPermitted = false")
            return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val own = runCatching { tm.selfManagedPhoneAccounts }.getOrDefault(emptyList())
            if (own.isNotEmpty() && handle !in own) {
                _status.value = Status(Availability.REFUSED, "self-managed account not registered")
                return false
            }
        }
        val extras = Bundle().apply {
            putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
            putInt(
                TelecomManager.EXTRA_START_CALL_WITH_VIDEO_STATE,
                if (kind == CallKind.VIDEO) VideoProfile.STATE_BIDIRECTIONAL else VideoProfile.STATE_AUDIO_ONLY,
            )
            putBundle(
                TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS,
                callExtras(callId, peerUserId, peerName, conversationId, kind),
            )
        }
        val ok = runCatching { tm.placeCall(address, extras) }
        if (ok.isFailure) {
            _status.value = Status(Availability.REFUSED, ok.exceptionOrNull()?.message ?: "placeCall threw")
            return false
        }
        _status.value = Status(Availability.READY)
        return true
    }

    /**
     * Ask Telecom to own an incoming call.
     *
     * On success Telecom calls back into [VoiidConnectionService], and the ring notification
     * is posted from [VoiidConnection.onShowIncomingCallUi] instead of directly — that is the
     * point: the ring appears exactly when the OS permits it, and not at all if a cellular
     * call is already up.
     *
     * TIMING: Telecom allows 5 seconds between this call and the notification being posted.
     * Nothing on this path may wait on the network — the caller's name comes from the local
     * directory only (see [CallManager.resolvePeerName]).
     */
    fun reportIncoming(
        context: Context,
        callId: String,
        peerUserId: String,
        peerName: String,
        conversationId: String?,
        kind: CallKind,
        phoneE164: String?,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return reportIncomingImpl(context, callId, peerUserId, peerName, conversationId, kind, phoneE164)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    @SuppressLint("MissingPermission")   // MANAGE_OWN_CALLS, declared in the manifest.
    private fun reportIncomingImpl(
        context: Context,
        callId: String,
        peerUserId: String,
        peerName: String,
        conversationId: String?,
        kind: CallKind,
        phoneE164: String?,
    ): Boolean {
        val tm = context.getSystemService(TelecomManager::class.java) ?: return false
        val handle = accountHandle ?: return false
        if (!runCatching { tm.isIncomingCallPermitted(handle) }.getOrDefault(false)) {
            _status.value = Status(Availability.REFUSED, "isIncomingCallPermitted = false")
            return false
        }
        val extras = callExtras(callId, peerUserId, peerName, conversationId, kind).apply {
            putParcelable(
                TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                makeHandle(phoneE164, peerUserId),
            )
        }
        val ok = runCatching { tm.addNewIncomingCall(handle, extras) }
        if (ok.isFailure) {
            _status.value = Status(
                Availability.REFUSED,
                ok.exceptionOrNull()?.message ?: "addNewIncomingCall threw",
            )
            return false
        }
        _status.value = Status(Availability.READY)
        return true
    }

    private fun callExtras(
        callId: String,
        peerUserId: String,
        peerName: String,
        conversationId: String?,
        kind: CallKind,
    ) = Bundle().apply {
        putString(EXTRA_CALL_ID, callId)
        putString(EXTRA_PEER_USER_ID, peerUserId)
        putString(EXTRA_PEER_NAME, peerName)
        putString(EXTRA_CONVERSATION_ID, conversationId)
        putBoolean(EXTRA_VIDEO, kind == CallKind.VIDEO)
    }

    // ---- driving the Connection from the engine --------------------------------

    internal fun attach(callId: String, connection: VoiidConnection) {
        // The call already ended while Telecom was still binding: finish this Connection
        // immediately instead of registering it, or it leaks as a phantom ongoing call.
        val pending = pendingDisconnects.remove(callId)
        if (pending != null) {
            runCatching { connection.finish(pending) }
            return
        }
        connections[callId] = connection
        // Telecom binds ASYNCHRONOUSLY — placeCall/addNewIncomingCall return immediately and
        // the Connection arrives some milliseconds later, by which time the engine has already
        // opened the mic and taken the audio route through AudioManager (it cannot wait: that
        // delay would be audible at the start of every call). Hand the route over now, or the
        // two owners fight for the rest of the call.
        runCatching { CallManager.onTelecomAssumedAudio(callId) }
    }

    internal fun detach(callId: String) {
        connections.remove(callId)
    }

    /** Non-null only while Telecom actually owns this call. */
    fun connection(callId: String): VoiidConnection? = connections[callId]

    /**
     * A better caller name finished resolving after the ring was already raised (see
     * [CallManager.refinePeerName]). No-op when Telecom never took the call.
     */
    fun updateCallerName(callId: String, name: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            connections[callId]?.setCallerDisplayName(name, TelecomManager.PRESENTATION_ALLOWED)
        }
    }

    /** Media is up. Mirrors [CallManager.markConnected]. */
    fun setActive(callId: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching { connections[callId]?.setActive() }
    }

    /**
     * The call ended. [cause] must be one of [DisconnectCause]'s codes.
     *
     * MISSED IS LOAD-BEARING: [DisconnectCause.MISSED] is what files a red missed-call entry,
     * exactly as iOS's `.unanswered` does. Reporting REMOTE or LOCAL for a call nobody
     * answered files it as a completed call and the miss becomes invisible — which is the
     * single most valuable row in the whole log.
     */
    fun setDisconnected(callId: String, cause: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val conn = connections.remove(callId)
        if (conn == null) {
            // The Connection has not bound yet. Record the cause so attach() finishes it the
            // moment it is created, rather than dropping the disconnect and leaking it.
            // Bounded by the call_id space and cleared on attach; a placeCall that Telecom
            // never honours self-expires from the caller's perspective (nothing references it).
            pendingDisconnects[callId] = cause
            return
        }
        runCatching { conn.finish(cause) }
    }

    /**
     * Route audio through Telecom instead of [android.media.AudioManager].
     *
     * Returns false when Telecom does not own this call, and the engine then uses its own
     * AudioManager path unchanged. When it DOES own the call the two must never both act:
     * a self-managed app that also calls `setCommunicationDevice`/`startBluetoothSco` fights
     * the platform for the route, and the symptom is device-specific — audio stuck on the
     * earpiece, Bluetooth never engaging, or a route that flips back a second after the user
     * changes it.
     */
    fun setAudioRoute(callId: String, speaker: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val conn = connections[callId] ?: return false
        return runCatching { conn.applyRoutePreference(speaker) }.getOrDefault(false)
    }
}

/** DisconnectCause codes, kept next to the mapping that produces them. */
internal object TelecomCause {
    const val LOCAL = DisconnectCause.LOCAL
    const val REMOTE = DisconnectCause.REMOTE
    const val MISSED = DisconnectCause.MISSED
    const val REJECTED = DisconnectCause.REJECTED
    const val BUSY = DisconnectCause.BUSY
    const val ERROR = DisconnectCause.ERROR
    const val CANCELED = DisconnectCause.CANCELED
}

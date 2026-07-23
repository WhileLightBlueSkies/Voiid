package com.voiid.app.net

import android.os.Build
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import androidx.annotation.RequiresApi

/**
 * The `ConnectionService` Telecom binds to when it takes ownership of a Voiid call.
 *
 * Thin by design: it does nothing but rebuild a [VoiidConnection] from the extras
 * [TelecomBridge] threaded through, because Telecom may bind a freshly-started process and
 * cannot be assumed to see whatever [CallManager] happens to hold in memory.
 *
 * The account is SELF-MANAGED, so we are not a dialer replacement and never appear in the
 * user's calling-account picker: Voiid keeps its own in-app call UI ([com.voiid.app.main.CallScreens])
 * and Telecom is only there for arbitration, the call log, and the remote surfaces
 * (Bluetooth, Wear, Auto).
 *
 * API 26+. On older devices [TelecomBridge] never registers the account, so this is never
 * bound and the app behaves exactly as it did before.
 */
@RequiresApi(Build.VERSION_CODES.O)
class VoiidConnectionService : ConnectionService() {

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection? = build(request, incoming = false)

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection? = build(request, incoming = true)

    /**
     * Telecom refused the call after we asked (an emergency call started, or another app's
     * unholdable call is up). The in-app call is already running and is NOT torn down here —
     * a Telecom refusal must only cost us the system integration, never the call itself.
     */
    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        android.util.Log.w("VOIID", "Telecom refused the outgoing call — continuing in-app only")
    }

    /**
     * Same for an inbound call. The ring notification normally comes from
     * [VoiidConnection.onShowIncomingCallUi]; since no Connection will ever exist, fall back
     * to posting it directly so the user is still alerted.
     */
    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        android.util.Log.w("VOIID", "Telecom refused the incoming call — falling back to the in-app ring")
        val extras = request?.extras ?: return
        val name = extras.getString(TelecomBridge.EXTRA_PEER_NAME) ?: return
        runCatching {
            CallForegroundService.showIncoming(
                applicationContext, name, extras.getBoolean(TelecomBridge.EXTRA_VIDEO, false),
            )
        }
    }

    private fun build(request: ConnectionRequest?, incoming: Boolean): Connection? {
        val extras = request?.extras
        val callId = extras?.getString(TelecomBridge.EXTRA_CALL_ID)
        val peerUserId = extras?.getString(TelecomBridge.EXTRA_PEER_USER_ID)
        if (callId.isNullOrBlank() || peerUserId.isNullOrBlank()) {
            // Not one of ours (or a malformed request). Refusing beats inventing a call.
            return Connection.createFailedConnection(DisconnectCause(DisconnectCause.ERROR))
        }
        val video = extras.getBoolean(TelecomBridge.EXTRA_VIDEO, false)
        // The name is resolved LOCALLY, never taken from signaling — same rule as the rest of
        // the call path (see CallManager.resolvePeerName). It is passed through the extras so
        // this works in a cold, push-woken process without a database hit on the 5s budget.
        val peerName = extras.getString(TelecomBridge.EXTRA_PEER_NAME)?.takeIf { it.isNotBlank() }
            ?: com.voiid.app.store.UserDirectory.displayName(peerUserId)

        val conn = VoiidConnection(
            appContext = applicationContext,
            callId = callId,
            peerUserId = peerUserId,
            peerName = peerName,
            conversationId = extras.getString(TelecomBridge.EXTRA_CONVERSATION_ID),
            video = video,
            incoming = incoming,
        )
        conn.connectionProperties = Connection.PROPERTY_SELF_MANAGED
        conn.connectionCapabilities = Connection.CAPABILITY_HOLD or Connection.CAPABILITY_SUPPORT_HOLD
        // The address is what the OS matches against the address book and writes to the call
        // log; `request.address` already carries the tel:/voiid: Uri TelecomBridge built.
        request.address?.let { conn.setAddress(it, TelecomManager.PRESENTATION_ALLOWED) }
        // Shown until the system finishes contact matching, and it carries OUR resolved name
        // (which respects the address-book name the user saved) rather than whatever the OS
        // decides from the number alone.
        conn.setCallerDisplayName(peerName, TelecomManager.PRESENTATION_ALLOWED)
        conn.videoState = if (video) VideoProfile.STATE_BIDIRECTIONAL else VideoProfile.STATE_AUDIO_ONLY
        conn.audioModeIsVoip = true
        if (incoming) conn.setRinging() else conn.setDialing()

        TelecomBridge.attach(callId, conn)
        return conn
    }
}

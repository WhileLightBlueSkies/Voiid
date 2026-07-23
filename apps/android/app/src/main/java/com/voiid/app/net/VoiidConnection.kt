package com.voiid.app.net

import android.content.Context
import android.content.Intent
import android.os.Build
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.DisconnectCause
import androidx.annotation.RequiresApi
import com.voiid.app.MainActivity

/**
 * One live call as Telecom sees it — the Android counterpart of a CXCall.
 *
 * It is a REMOTE CONTROL for [CallManager], never a second state machine. Every override
 * here forwards into the engine and then returns; the engine's own teardown path is what
 * eventually calls [finish]. That asymmetry is deliberate: there is exactly one place a
 * call can end (`CallManager.endInternal`), so a hang-up from a watch, a Bluetooth headset
 * button, Android Auto and the in-app button all converge on the same code and cannot
 * produce divergent state.
 *
 * TIMING: Telecom gives ~5 seconds for each of these callbacks. Nothing here may block or
 * wait on the network.
 */
@RequiresApi(Build.VERSION_CODES.O)
class VoiidConnection(
    private val appContext: Context,
    val callId: String,
    val peerUserId: String,
    val peerName: String,
    val conversationId: String?,
    val video: Boolean,
    val incoming: Boolean,
) : Connection() {

    /** Set once we have reported a DisconnectCause, so teardown can never run twice. */
    @Volatile private var terminated = false

    /**
     * A speaker/earpiece preference expressed before Telecom told us what routes exist.
     * Applied on the first [onCallAudioStateChanged] and then cleared — it must NOT be
     * re-applied on every route change, or the user could never move the audio from a
     * Bluetooth headset's own controls.
     */
    @Volatile private var pendingSpeaker: Boolean? = null

    // ---- OS -> engine ----------------------------------------------------------

    /**
     * SELF-MANAGED ONLY, and the reason the ring notification moved here from
     * `CallManager.onRingPush`: Telecom calls this when it has decided our call may
     * actually alert the user. Post the ring any earlier and we would ring over a cellular
     * call the OS was about to hand priority to.
     *
     * Budget: the notification must be posted within 5 seconds of `addNewIncomingCall`.
     */
    override fun onShowIncomingCallUi() {
        runCatching { CallForegroundService.showIncoming(appContext, peerName, video) }
    }

    override fun onAnswer() = answer()

    override fun onAnswer(videoState: Int) = answer()

    private fun answer() {
        runCatching { CallForegroundService.cancelIncoming(appContext) }
        // Answered from a watch / headset / Auto: bring the in-call UI forward too, so the
        // user isn't left in a call with no visible surface (and, for video, no preview).
        runCatching {
            appContext.startActivity(
                Intent(appContext, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
        }
        runCatching { CallManager.accept() }
        endIfEngineGone(DisconnectCause.LOCAL)
    }

    override fun onReject() {
        runCatching { CallForegroundService.cancelIncoming(appContext) }
        runCatching { CallManager.decline() }
        endIfEngineGone(DisconnectCause.REJECTED)
    }

    override fun onDisconnect() {
        runCatching { CallManager.hangup() }
        endIfEngineGone(DisconnectCause.LOCAL)
    }

    /** Telecom abandoned the call before it was ever set up (e.g. a failed outgoing dial). */
    override fun onAbort() {
        runCatching { CallManager.hangup() }
        endIfEngineGone(DisconnectCause.CANCELED)
    }

    override fun onHold() {
        if (CallManager.state.value?.onHold == false) runCatching { CallManager.toggleHold() }
        runCatching { setOnHold() }
    }

    override fun onUnhold() {
        if (CallManager.state.value?.onHold == true) runCatching { CallManager.toggleHold() }
        runCatching { setActive() }
    }

    /**
     * The route changed — either because we asked, or because the user moved it from the
     * system UI, a Bluetooth headset or Android Auto. Mirror it back into the in-app state so
     * the speaker button in [com.voiid.app.main.CallScreens] agrees with reality; the two
     * disagreeing is exactly the bug that made the in-app toggle feel broken.
     *
     * DEPRECATION, deliberately kept: `CallAudioState` was superseded by `CallEndpoint` in
     * API 34. minSdk here is 24, and the endpoint API has no compat shim outside
     * androidx.core-telecom, so this remains the ONE call-back that fires on every device we
     * ship to. Migrating would mean maintaining two routing paths for a behaviour that must
     * be identical on both.
     */
    @Deprecated("CallAudioState superseded by CallEndpoint in API 34; kept for minSdk 24 coverage")
    @Suppress("DEPRECATION")
    override fun onCallAudioStateChanged(state: CallAudioState) {
        pendingSpeaker?.let { want ->
            pendingSpeaker = null
            runCatching { route(state, want) }
        }
        runCatching {
            CallManager.onSystemAudioRouteChanged(state.route == CallAudioState.ROUTE_SPEAKER)
        }
    }

    // ---- engine -> OS ----------------------------------------------------------

    /**
     * Express the engine's speaker preference through Telecom. Returns true once this
     * Connection has taken ownership of the route, which is the signal to [CallManager] that
     * it must NOT touch AudioManager for this call.
     *
     * An external device (Bluetooth / wired headset) always wins over the speaker-vs-earpiece
     * choice — same rule the AudioManager path it replaces used, and what every other calling
     * app does.
     */
    @Suppress("DEPRECATION")   // see onCallAudioStateChanged: CallAudioState is our minSdk-24 path
    fun applyRoutePreference(speaker: Boolean): Boolean {
        val state = callAudioState
        if (state == null) {
            // Telecom hasn't published the audio state yet. Own the route anyway (returning
            // false here would let AudioManager grab it and then fight us a moment later).
            pendingSpeaker = speaker
            return true
        }
        route(state, speaker)
        return true
    }

    @Suppress("DEPRECATION")   // see onCallAudioStateChanged
    private fun route(state: CallAudioState, speaker: Boolean) {
        val supported = state.supportedRouteMask
        val target = when {
            supported and CallAudioState.ROUTE_BLUETOOTH != 0 -> CallAudioState.ROUTE_BLUETOOTH
            supported and CallAudioState.ROUTE_WIRED_HEADSET != 0 -> CallAudioState.ROUTE_WIRED_HEADSET
            speaker && supported and CallAudioState.ROUTE_SPEAKER != 0 -> CallAudioState.ROUTE_SPEAKER
            supported and CallAudioState.ROUTE_EARPIECE != 0 -> CallAudioState.ROUTE_EARPIECE
            else -> return
        }
        if (state.route == target) return
        runCatching { setAudioRoute(target) }
    }

    /**
     * Report the final outcome and release the Connection. Idempotent.
     *
     * [cause] decides what the system call log shows, so it is not cosmetic — see
     * [TelecomBridge.setDisconnected] on why MISSED specifically matters.
     */
    fun finish(cause: Int) {
        if (terminated) return
        terminated = true
        runCatching { setDisconnected(DisconnectCause(cause)) }
        runCatching { destroy() }
        TelecomBridge.detach(callId)
    }

    /**
     * Telecom asked us to end a call the engine no longer knows about (it had already torn
     * down, or never got as far as creating state). Without this the Connection would sit in
     * Telecom forever and block every subsequent call.
     */
    private fun endIfEngineGone(cause: Int) {
        if (CallManager.state.value?.callId == callId) return
        finish(cause)
    }
}

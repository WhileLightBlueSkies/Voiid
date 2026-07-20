package com.voiid.app.main

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.Display
import androidx.activity.ComponentActivity
import androidx.annotation.RequiresApi
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.core.util.Consumer
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.voiid.app.net.CallForegroundService
import com.voiid.app.net.CallManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/**
 * Picture-in-Picture state shared between the activity (which owns the PiP APIs) and
 * Compose (which must strip all call chrome down to bare remote video while in PiP).
 *
 * Kept as a plain object rather than a CompositionLocal so the values survive the
 * configuration change that the PiP resize produces.
 */
object CallPipState {

    private val _inPip = MutableStateFlow(false)
    /** True while the call UI is hosted in the system PiP window. */
    val inPip: StateFlow<Boolean> = _inPip.asStateFlow()

    internal fun setInPip(value: Boolean) { _inPip.value = value }

    /**
     * Remote video frame size, as reported by the renderer's `onFrameResolutionChanged`.
     * PiP params track this so the window matches the real video aspect instead of a
     * hardcoded guess, and update live if the sender rotates or renegotiates resolution.
     */
    private val _remoteAspect = MutableStateFlow<Rational?>(null)
    internal val remoteAspect: StateFlow<Rational?> = _remoteAspect.asStateFlow()

    /**
     * Publish the decoded remote frame geometry. [rotation] is the frame rotation in degrees
     * as delivered by WebRTC; at 90/270 the displayed width/height are swapped.
     */
    fun setRemoteVideoSize(width: Int, height: Int, rotation: Int) {
        if (width <= 0 || height <= 0) return
        val swap = rotation == 90 || rotation == 270
        val w = if (swap) height else width
        val h = if (swap) width else height
        _remoteAspect.value = clampAspect(w, h)
    }

    internal fun restoreAspect(numerator: Int, denominator: Int) {
        if (numerator <= 0 || denominator <= 0) return
        _remoteAspect.value = clampAspect(numerator, denominator)
    }

    /**
     * Window bounds of the remote-video renderer, published by the call UI so PiP can use
     * them as `setSourceRectHint` for a seamless enter animation. Null when not laid out.
     */
    @Volatile
    private var remoteVideoBounds: Rect? = null

    fun setRemoteVideoBounds(rect: Rect?) { remoteVideoBounds = rect }

    internal fun remoteVideoBoundsOrNull(): Rect? = remoteVideoBounds?.takeIf { !it.isEmpty }

    /**
     * The platform rejects PiP aspect ratios outside roughly 1:2.39 .. 2.39:1, throwing
     * rather than clamping, so clamp before we ever hand a ratio to the system.
     */
    private fun clampAspect(width: Int, height: Int): Rational {
        val ratio = width.toDouble() / height.toDouble()
        return when {
            ratio > MAX_ASPECT -> Rational(239, 100)
            ratio < MIN_ASPECT -> Rational(100, 239)
            else -> Rational(width, height)
        }
    }

    private const val MAX_ASPECT = 2.39
    private const val MIN_ASPECT = 1.0 / 2.39
}

/**
 * Observe PiP mode from Compose via the AndroidX activity listener (cleaner than reaching
 * for the `onPictureInPictureModeChanged` override, and correctly scoped to the composition).
 */
@Composable
fun rememberIsInPipMode(): State<Boolean> {
    val context = androidx.compose.ui.platform.LocalContext.current
    val activity = remember(context) { context.findComponentActivity() }
    val inPip = remember {
        mutableStateOf(
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                activity?.isInPictureInPictureMode == true,
        )
    }
    DisposableEffect(activity) {
        if (activity == null) return@DisposableEffect onDispose { }
        val listener = Consumer<androidx.core.app.PictureInPictureModeChangedInfo> { info ->
            inPip.value = info.isInPictureInPictureMode
        }
        activity.addOnPictureInPictureModeChangedListener(listener)
        onDispose { activity.removeOnPictureInPictureModeChangedListener(listener) }
    }
    return inPip
}

private fun android.content.Context.findComponentActivity(): ComponentActivity? {
    var ctx: android.content.Context? = this
    while (ctx is android.content.ContextWrapper) {
        if (ctx is ComponentActivity) return ctx
        ctx = ctx.baseContext
    }
    return null
}

/**
 * Owns every Picture-in-Picture interaction for the call-hosting activity.
 *
 * Responsibilities:
 * - decide whether the current call is PiP-eligible (connected **video** call only),
 * - keep [PictureInPictureParams] fresh (live aspect ratio, source-rect hint, mute/hangup actions),
 * - opt into Android 12+ seamless auto-enter reactively, with `onUserLeaveHint` as the pre-12 path,
 * - close the PiP window when the call ends so no orphan window is left behind,
 * - show the call over the keyguard when one is ringing/active.
 *
 * Robustness note: devices routinely *lie* about PiP. A device can report
 * [PackageManager.FEATURE_PICTURE_IN_PICTURE] and still throw from
 * `enterPictureInPictureMode` / `setPictureInPictureParams` (OEM builds, PiP disabled per-app
 * in settings, or a bad activity state). Every one of those calls is therefore wrapped — a
 * failure degrades to "call continues normally, no PiP", never a crash.
 */
class CallPipController(private val activity: ComponentActivity) {

    private val pipSupported: Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /** Set once we enter PiP for a call, so we know a PiP window must be torn down on end. */
    private var enteredPipForCall = false

    /** Attach lifecycle-scoped observers. Call once from `onCreate`. */
    fun attach(owner: LifecycleOwner) {
        activity.addOnPictureInPictureModeChangedListener { info ->
            onPipModeChanged(info.isInPictureInPictureMode)
        }
        owner.lifecycleScope.launch {
            owner.lifecycle.repeatOnLifecycle(Lifecycle.State.CREATED) {
                // Params must be re-pushed on call-state changes (mute label, auto-enter
                // eligibility) *and* whenever the remote video aspect changes.
                combine(CallManager.state, CallPipState.remoteAspect) { state, aspect -> state to aspect }
                    .distinctUntilChanged()
                    .collect { (state, _) -> onCallState(state) }
            }
        }
    }

    // ---- instance state --------------------------------------------------------

    /**
     * Persist the aspect ratio so a recreation while in PiP doesn't snap the window to a
     * default ratio before the first remote frame arrives.
     */
    fun onSaveInstanceState(outState: Bundle) {
        CallPipState.remoteAspect.value?.let {
            outState.putInt(KEY_ASPECT_NUM, it.numerator)
            outState.putInt(KEY_ASPECT_DEN, it.denominator)
        }
    }

    fun onRestoreInstanceState(savedState: Bundle?) {
        val state = savedState ?: return
        val num = state.getInt(KEY_ASPECT_NUM, 0)
        val den = state.getInt(KEY_ASPECT_DEN, 0)
        if (num > 0 && den > 0) CallPipState.restoreAspect(num, den)
    }

    // ---- call-state reactions --------------------------------------------------

    private fun onCallState(state: CallManager.CallState?) {
        applyKeyguardFlags(state != null)

        if (state == null || state.phase == CallManager.Phase.ENDED) {
            // The call is over and the PiP window must not outlive it. There is no public
            // "exit PiP" API, but relaunching this activity onto the front of its own task
            // pulls it out of PiP back into full screen — which is what we want in a
            // single-activity app: the user lands back in VOIID instead of the whole app
            // disappearing (which is what a bare finish() does here). finish() is kept only
            // as a last-resort fallback so we can never strand an orphan PiP window.
            if (enteredPipForCall && isInPipNow()) {
                enteredPipForCall = false
                CallPipState.setInPip(false)
                val restored = runCatching {
                    activity.startActivity(
                        Intent(activity, activity::class.java).addFlags(
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP
                        )
                    )
                }.isSuccess
                if (!restored) runCatching { activity.finish() }
            }
            enteredPipForCall = false
            clearAutoEnter()
            return
        }

        // Keeps the mute action's label/icon and the auto-enter flag in sync with call state.
        updatePipParams(state)
    }

    /** A connected video call is the only thing worth putting in a PiP window. */
    private fun isPipEligible(state: CallManager.CallState?): Boolean =
        pipSupported &&
            state != null &&
            state.kind == CallKind.VIDEO &&
            state.phase == CallManager.Phase.CONNECTED

    // ---- activity callbacks ----------------------------------------------------

    /**
     * Pre-Android-12 path (and a belt-and-braces fallback on 12+): the user pressed Home or
     * Recents while a video call is connected, so enter PiP explicitly.
     */
    fun onUserLeaveHint() {
        val state = CallManager.state.value
        if (!isPipEligible(state)) return
        if (isInPipNow()) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        // The device may have lied about supporting PiP — a throw here must not end the call.
        val entered = runCatching {
            activity.enterPictureInPictureMode(buildParams(state!!))
        }.getOrDefault(false)
        if (entered) enteredPipForCall = true
    }

    /** Mirror the system's PiP mode into [CallPipState] so Compose can hide/restore chrome. */
    fun onPipModeChanged(isInPictureInPictureMode: Boolean) {
        CallPipState.setInPip(isInPictureInPictureMode)
        if (isInPictureInPictureMode) {
            enteredPipForCall = true
        } else {
            enteredPipForCall = false
            // Returning to full screen: re-assert params for the next entry.
            updatePipParams(CallManager.state.value)
        }
    }

    fun isInPipNow(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity.isInPictureInPictureMode

    // ---- params ----------------------------------------------------------------

    /** Recompute and push [PictureInPictureParams]; no-op when PiP is unavailable. */
    fun updatePipParams(state: CallManager.CallState? = CallManager.state.value) {
        if (!pipSupported || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (!isPipEligible(state)) { clearAutoEnter(); return }
        // System may lie about PiP availability; never let a params push crash the call.
        runCatching { activity.setPictureInPictureParams(buildParams(state!!)) }
    }

    /** Turn auto-enter back off so a non-video / ended call never slips into PiP. */
    private fun clearAutoEnter() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        runCatching {
            activity.setPictureInPictureParams(
                PictureInPictureParams.Builder().setAutoEnterEnabled(false).build(),
            )
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun buildParams(state: CallManager.CallState): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(currentAspect())
            .setActions(pipActions(state))

        CallPipState.remoteVideoBoundsOrNull()?.let { builder.setSourceRectHint(it) }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Seamless auto-PiP on Android 12+: the system enters PiP on its own when the
            // user leaves, which looks far better than the onUserLeaveHint transition.
            builder.setAutoEnterEnabled(true)
            // Video content should letterbox rather than stretch during the resize.
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    /**
     * Prefer the live remote-video aspect. Before the first frame arrives, fall back to the
     * *display* orientation from [DisplayManager] — deliberately not the activity/window
     * Configuration, which reports the PiP window's own geometry while in PiP and would
     * feed a wrong ratio straight back into the next params update.
     */
    private fun currentAspect(): Rational {
        CallPipState.remoteAspect.value?.let { return it }
        val rotation = runCatching {
            val dm = activity.getSystemService(DisplayManager::class.java)
            dm?.getDisplay(Display.DEFAULT_DISPLAY)?.rotation ?: Display.DEFAULT_DISPLAY
        }.getOrDefault(0)
        val landscape = rotation == android.view.Surface.ROTATION_90 ||
            rotation == android.view.Surface.ROTATION_270
        return if (landscape) Rational(16, 9) else Rational(9, 16)
    }

    /**
     * Mute + hang-up controls for the PiP window. PiP windows are far too small for the normal
     * call chrome, so these two [RemoteAction]s are the only in-PiP controls the user gets.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun pipActions(state: CallManager.CallState): List<RemoteAction> {
        val actions = ArrayList<RemoteAction>(2)

        val muteLabel = if (state.muted) "Unmute" else "Mute"
        val muteIcon = if (state.muted) {
            android.R.drawable.ic_lock_silent_mode
        } else {
            android.R.drawable.ic_lock_silent_mode_off
        }
        actions.add(
            RemoteAction(
                Icon.createWithResource(activity, muteIcon),
                muteLabel,
                muteLabel,
                broadcast(CallForegroundService.ACTION_TOGGLE_MUTE, REQ_MUTE),
            ),
        )
        actions.add(
            RemoteAction(
                Icon.createWithResource(activity, android.R.drawable.ic_menu_close_clear_cancel),
                "End call",
                "End call",
                broadcast(CallForegroundService.ACTION_HANGUP, REQ_HANGUP),
            ),
        )
        return actions
    }

    private fun broadcast(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(activity, com.voiid.app.net.CallActionReceiver::class.java)
            .setAction(action)
            .setPackage(activity.packageName)
        return PendingIntent.getBroadcast(
            activity,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    // ---- keyguard --------------------------------------------------------------

    /**
     * Let the call UI appear over the lock screen when answering from a killed/locked state.
     * API 27+ uses the supported activity APIs; older releases fall back to window flags.
     */
    private fun applyKeyguardFlags(callActive: Boolean) {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                activity.setShowWhenLocked(callActive)
                activity.setTurnScreenOn(callActive)
            }
            @Suppress("DEPRECATION")
            val flags = android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (callActive) activity.window.addFlags(flags) else activity.window.clearFlags(flags)
        }
    }

    private companion object {
        const val REQ_MUTE = 41
        const val REQ_HANGUP = 42
        const val KEY_ASPECT_NUM = "voiid_pip_aspect_num"
        const val KEY_ASPECT_DEN = "voiid_pip_aspect_den"
    }
}

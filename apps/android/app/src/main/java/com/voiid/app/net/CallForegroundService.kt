package com.voiid.app.net

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.voiid.app.MainActivity
import com.voiid.app.R
import com.voiid.app.main.CallKind

/**
 * Keeps a live 1:1 call running while the app is backgrounded and surfaces incoming
 * calls over the lockscreen.
 *
 * - Ongoing call → a foreground [Service] (type microphone, plus camera for video) with a
 *   persistent "Ongoing call" notification so the OS won't kill mic/camera capture.
 * - Incoming call → a high-importance notification with a `fullScreenIntent`, so the ringing
 *   UI appears over the lockscreen. Decline routes through [CallActionReceiver]; Accept goes
 *   straight to [MainActivity] (see [acceptActivityIntent] for why it must).
 *
 * The engine ([CallManager]) owns all WebRTC state; this class is only OS glue.
 */
class CallForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val video = intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "VOIID call"
        ensureOngoingChannel(this)
        val notif = ongoingNotification(this, title)

        // Android 14 tightened microphone/camera FGS: the type is rejected outright if the
        // matching runtime permission isn't held, and the whole start is rejected if the app
        // isn't in an allowed state. Degrade step by step rather than crashing a live call.
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (video && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && hasCameraPermission()) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            // `phoneCall` is the type Android 14+ expects for a Telecom-integrated call, but
            // it is only legal while a self-managed Connection actually exists — asserting it
            // otherwise throws. Gated on the live Connection, never on the mere fact that we
            // hold MANAGE_OWN_CALLS. (The recoverCatching below still covers OEMs that refuse.)
            if (TelecomBridge.hasActiveConnection) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
            }
            runCatching { startForeground(ONGOING_ID, notif, type) }
                .recoverCatching { startForeground(ONGOING_ID, notif) }
                .isSuccess
        } else {
            runCatching { startForeground(ONGOING_ID, notif) }.isSuccess
        }

        // `running` gates whether CallManager may keep the camera capturing in the background:
        // without a live camera-type FGS, Android will hand us black frames.
        running = started
        if (!started) {
            runCatching { stopSelf() }
            return START_NOT_STICKY
        }
        return START_NOT_STICKY
    }

    /**
     * The user swiped VOIID out of Recents mid-call. Tear the call down properly and notify
     * the peer, otherwise they're left staring at a zombie call that never rings off.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        runCatching { CallManager.hangupFromSystem() }
        runCatching { GroupCallManager.leaveFromSystem() }
        running = false
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        runCatching { stopSelf() }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun hasCameraPermission(): Boolean =
        androidx.core.content.ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.CAMERA,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

    companion object {
        private const val ONGOING_CHANNEL = "voiid_call_ongoing"
        /**
         * `_v2` because this channel is now SILENT — [CallTones] owns the ringtone and the
         * vibration, and a channel that also sounded would ding once on top of the loop. A
         * channel's sound cannot be changed after creation, so a new id is the only way to
         * move already-installed devices off the old one.
         */
        private const val INCOMING_CHANNEL = "voiid_call_incoming_v2"
        private const val LEGACY_INCOMING_CHANNEL = "voiid_call_incoming"
        /**
         * Call waiting keeps a SOUNDING channel: the looping ringer is for a phone sitting
         * idle across the room, and running it over a call in progress would be hostile.
         */
        private const val WAITING_CHANNEL = "voiid_call_waiting"
        private const val ONGOING_ID = 4711
        private const val INCOMING_ID = 4712
        private const val WAITING_ID = 4713
        const val EXTRA_VIDEO = "video"
        const val EXTRA_TITLE = "title"

        const val ACTION_ACCEPT = "com.voiid.app.CALL_ACCEPT"
        const val ACTION_DECLINE = "com.voiid.app.CALL_DECLINE"
        /** Fired by the PiP window's mute RemoteAction. */
        const val ACTION_TOGGLE_MUTE = "com.voiid.app.CALL_TOGGLE_MUTE"
        /** Fired by the PiP window's hang-up RemoteAction. */
        const val ACTION_HANGUP = "com.voiid.app.CALL_HANGUP"
        /** Call-waiting notification: take the second call (ending the current one). */
        const val ACTION_WAITING_ACCEPT = "com.voiid.app.CALL_WAITING_ACCEPT"
        /** Call-waiting notification: reject the second call, keep the current one. */
        const val ACTION_WAITING_DECLINE = "com.voiid.app.CALL_WAITING_DECLINE"

        /**
         * True while the foreground service is actually holding its mic/camera FGS types.
         * If a start was rejected (Android 14 background-start rules, revoked permission),
         * this stays false and the engine stops trusting background camera capture.
         */
        @Volatile
        var running: Boolean = false
            private set

        /**
         * True while the incoming-call notification is actually posted.
         *
         * The caller's name resolves asynchronously (see [CallManager.refinePeerName]), and a
         * re-post carrying the better name must never be what FIRST raises the ring: with
         * Telecom adopted it is Telecom that decides when we are allowed to alert.
         */
        @Volatile
        var incomingShown: Boolean = false
            private set

        /** Promote the ongoing call to a foreground service. */
        fun start(context: Context, state: CallManager.CallState) {
            val i = Intent(context, CallForegroundService::class.java).apply {
                putExtra(EXTRA_VIDEO, state.kind == CallKind.VIDEO)
                putExtra(EXTRA_TITLE, state.peerName)
            }
            // On Android 12+ a background FGS start throws ForegroundServiceStartNotAllowed.
            // Incoming calls arrive on a high-priority FCM message, which grants a temporary
            // allowlist window, but that window can expire — never let it crash the call.
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(i)
                else context.startService(i)
            }
        }

        /**
         * Promote an ongoing GROUP call ([GroupCallManager]) to a foreground service, so mic
         * and camera keep capturing while the app is backgrounded. Same service, same
         * notification — a group and a 1:1 call are mutually exclusive, so they can never
         * contend for it.
         */
        fun startGroup(context: Context, title: String, video: Boolean) {
            val i = Intent(context, CallForegroundService::class.java).apply {
                putExtra(EXTRA_VIDEO, video)
                putExtra(EXTRA_TITLE, title)
            }
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(i)
                else context.startService(i)
            }
        }

        fun stop(context: Context) {
            running = false
            cancelIncoming(context)
            runCatching { context.stopService(Intent(context, CallForegroundService::class.java)) }
        }

        /** Post the full-screen incoming-call notification (rings over the lockscreen). */
        fun showIncoming(context: Context, state: CallManager.CallState) =
            showIncoming(context, state.callId, state.peerName, state.kind == CallKind.VIDEO)

        /**
         * The same ring, addressed by name/kind rather than by [CallManager.CallState].
         *
         * Exists because with Telecom adopted the ring is normally posted from
         * [VoiidConnection.onShowIncomingCallUi] — a binder callback that may run in a
         * process where the engine has not published its state yet, and which carries its own
         * copy of the peer name in the ConnectionRequest extras. Same notification, same
         * channel, same full-screen intent; only the source of the two strings differs.
         */
        fun showIncoming(context: Context, callId: String?, peerName: String, video: Boolean) {
            // Android 13+: notify() without POST_NOTIFICATIONS is a silent no-op, so the call
            // would never ring and nothing anywhere would say why. The message path has always
            // checked this; the call path is the one where the silence actually costs a call.
            CallRingCapability.refresh(context)
            if (CallRingCapability.state.value.notificationsBlocked) {
                android.util.Log.e("VOIID", "POST_NOTIFICATIONS denied — no ring notification, sound only")
                // The ringtone needs no permission, and the in-call screen is driven by
                // CallManager.state, so opening Voiid still answers. Total silence would make
                // the call simply not have happened.
                CallTones.startIncomingRinger(context)
                return
            }
            if (CallRingCapability.state.value.fullScreenIntentBlocked) {
                android.util.Log.w("VOIID", "full-screen intent revoked — ring degrades to a heads-up")
            }
            ensureIncomingChannel(context)

            val full = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val fullPi = PendingIntent.getActivity(
                context, 0, full,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val acceptPi = PendingIntent.getActivity(
                context, 1, acceptActivityIntent(context, callId),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val declinePi = actionIntent(context, ACTION_DECLINE, 2)

            val kindLabel = if (video) "Incoming video call" else "Incoming voice call"
            val notif = NotificationCompat.Builder(context, INCOMING_CHANNEL)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(peerName)
                .setContentText(kindLabel)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setOngoing(true)
                .setAutoCancel(false)
                .setFullScreenIntent(fullPi, true)
                .setContentIntent(fullPi)
                .addAction(0, "Decline", declinePi)
                .addAction(0, "Accept", acceptPi)
                .build()

            runCatching { NotificationManagerCompat.from(context).notify(INCOMING_ID, notif) }
                .onSuccess {
                    incomingShown = true
                    // The channel is silent by design, so this is the whole ring.
                    CallTones.startIncomingRinger(context)
                }
                .onFailure { android.util.Log.e("VOIID", "incoming-call notify failed", it) }
        }

        fun cancelIncoming(context: Context) {
            incomingShown = false
            CallTones.stopIncomingRinger()
            runCatching { NotificationManagerCompat.from(context).cancel(INCOMING_ID) }
        }

        /**
         * The Intent that answers a ringing call by opening the app.
         *
         * ANSWERING MUST GO THROUGH AN ACTIVITY. Since Android 12 a notification action that
         * lands in a BroadcastReceiver may not start one — the notification-trampoline ban —
         * and the receiver's `startActivity` was silently dropped. The call was still answered,
         * so audio connected into no in-call UI at all, and on a video call neither the camera
         * nor the renderers were ever attached.
         *
         * [DeepLinkRouter.EXTRA_ACCEPT_CALL_ID] scopes the answer to this call, so a
         * PendingIntent left over from a call that has already ended can never answer whatever
         * happens to be ringing later.
         */
        private fun acceptActivityIntent(context: Context, callId: String?): Intent =
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(DeepLinkRouter.EXTRA_ACCEPT_CALL_ID, callId)
            }

        /**
         * Bring the in-call UI forward for a call answered from OUTSIDE the app — a watch, a
         * headset button, Android Auto, the system call UI. Carries the same accept extra as
         * the notification action, so whichever path arrives first answers and the other is a
         * no-op ([CallManager.accept] refuses a call that is no longer ringing).
         *
         * This is still a background activity start and the OS may drop it, which is why the
         * ring notification is cancelled only AFTER it: a dropped start then leaves the user
         * the full-screen intent as a way back into the call.
         */
        fun openInCallUi(context: Context, callId: String?) {
            runCatching { context.startActivity(acceptActivityIntent(context, callId)) }
        }

        /**
         * Post the CALL WAITING notification: a second call arrived while one is in progress.
         *
         * Separate notification id from [INCOMING_ID] so it can never replace or be replaced by
         * the ongoing call's own notification, and deliberately **not** a full-screen intent —
         * the user is mid-conversation and slamming a lockscreen takeover over a live call is
         * hostile. Its channel is the one that still *sounds*, so it alerts exactly as loudly as
         * the user's ringer mode says it should.
         */
        fun showWaiting(context: Context, call: CallManager.WaitingCall) {
            ensureWaitingChannel(context)
            val open = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val openPi = PendingIntent.getActivity(
                context, 3, open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            // Same trampoline rule as the ring's Accept action: taking the waiting call swaps
            // the live call out and must land the user on the new call's screen.
            val takePi = PendingIntent.getActivity(
                context, 6,
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra(DeepLinkRouter.EXTRA_ACCEPT_WAITING_CALL_ID, call.callId)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val notif = NotificationCompat.Builder(context, WAITING_CHANNEL)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(call.peerName)
                .setContentText("Call waiting — answering ends your current call")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setOngoing(true)
                .setAutoCancel(false)
                .setContentIntent(openPi)
                .addAction(0, "Decline", actionIntent(context, ACTION_WAITING_DECLINE, 5))
                .addAction(0, "End & answer", takePi)
                .build()
            runCatching { NotificationManagerCompat.from(context).notify(WAITING_ID, notif) }
        }

        fun cancelWaiting(context: Context) {
            runCatching { NotificationManagerCompat.from(context).cancel(WAITING_ID) }
        }

        private fun actionIntent(context: Context, action: String, req: Int): PendingIntent {
            val i = Intent(context, CallActionReceiver::class.java).setAction(action)
            return PendingIntent.getBroadcast(
                context, req, i,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun ongoingNotification(context: Context, title: String): Notification {
            val open = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val pi = PendingIntent.getActivity(
                context, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, ONGOING_CHANNEL)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText("Ongoing call")
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setOngoing(true)
                .setContentIntent(pi)
                .build()
        }

        private fun ensureOngoingChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            if (nm.getNotificationChannel(ONGOING_CHANNEL) != null) return
            nm.createNotificationChannel(
                NotificationChannel(ONGOING_CHANNEL, "Ongoing calls", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while a voice or video call is active"
                    setSound(null, null)
                },
            )
        }

        private fun ensureIncomingChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            if (nm.getNotificationChannel(LEGACY_INCOMING_CHANNEL) != null) {
                runCatching { nm.deleteNotificationChannel(LEGACY_INCOMING_CHANNEL) }
            }
            if (nm.getNotificationChannel(INCOMING_CHANNEL) != null) return
            nm.createNotificationChannel(
                NotificationChannel(INCOMING_CHANNEL, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Ringing notifications for incoming calls"
                    // CallTones owns both the ringtone loop and the vibration for the whole ring
                    // window; a channel that alerted too would ding once over the top of it.
                    setSound(null, null)
                    enableVibration(false)
                    setBypassDnd(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
        }

        private fun ensureWaitingChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            if (nm.getNotificationChannel(WAITING_CHANNEL) != null) return
            nm.createNotificationChannel(
                NotificationChannel(WAITING_CHANNEL, "Call waiting", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "A second call arriving while you are already on one"
                    enableVibration(true)
                    setBypassDnd(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
        }
    }
}

/**
 * Handles the notification actions that need NO UI: Decline, and the PiP window's controls.
 *
 * Accepting deliberately does not come through here. A BroadcastReceiver reached from a
 * notification action may not start an activity on Android 12+, so answering here connected
 * audio into a closed app — see [CallForegroundService.openInCallUi]. The ACCEPT actions
 * remain wired for headless callers (Telecom, an automation intent) that have already brought
 * the UI up, or genuinely have none.
 */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        CallManager.init(context)
        when (intent.action) {
            CallForegroundService.ACTION_ACCEPT -> {
                CallForegroundService.cancelIncoming(context)
                CallManager.accept()
            }
            CallForegroundService.ACTION_DECLINE -> {
                CallForegroundService.cancelIncoming(context)
                CallManager.decline()
            }
            // From the call-waiting notification.
            CallForegroundService.ACTION_WAITING_ACCEPT -> {
                CallForegroundService.cancelWaiting(context)
                CallManager.acceptWaiting()
            }
            CallForegroundService.ACTION_WAITING_DECLINE -> {
                CallForegroundService.cancelWaiting(context)
                CallManager.declineWaiting()
            }
            // From the PiP window's RemoteActions — the only controls that fit there.
            CallForegroundService.ACTION_TOGGLE_MUTE -> CallManager.toggleMute()
            CallForegroundService.ACTION_HANGUP -> CallManager.hangup()
        }
    }
}

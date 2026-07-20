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
 *   UI appears over the lockscreen; Accept/Decline actions route through [CallActionReceiver].
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
        private const val INCOMING_CHANNEL = "voiid_call_incoming"
        private const val ONGOING_ID = 4711
        private const val INCOMING_ID = 4712
        const val EXTRA_VIDEO = "video"
        const val EXTRA_TITLE = "title"

        const val ACTION_ACCEPT = "com.voiid.app.CALL_ACCEPT"
        const val ACTION_DECLINE = "com.voiid.app.CALL_DECLINE"
        /** Fired by the PiP window's mute RemoteAction. */
        const val ACTION_TOGGLE_MUTE = "com.voiid.app.CALL_TOGGLE_MUTE"
        /** Fired by the PiP window's hang-up RemoteAction. */
        const val ACTION_HANGUP = "com.voiid.app.CALL_HANGUP"

        /**
         * True while the foreground service is actually holding its mic/camera FGS types.
         * If a start was rejected (Android 14 background-start rules, revoked permission),
         * this stays false and the engine stops trusting background camera capture.
         */
        @Volatile
        var running: Boolean = false
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

        fun stop(context: Context) {
            running = false
            runCatching { NotificationManagerCompat.from(context).cancel(INCOMING_ID) }
            runCatching { context.stopService(Intent(context, CallForegroundService::class.java)) }
        }

        /** Post the full-screen incoming-call notification (rings over the lockscreen). */
        fun showIncoming(context: Context, state: CallManager.CallState) {
            ensureIncomingChannel(context)

            val full = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val fullPi = PendingIntent.getActivity(
                context, 0, full,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val acceptPi = actionIntent(context, ACTION_ACCEPT, 1)
            val declinePi = actionIntent(context, ACTION_DECLINE, 2)

            val kindLabel = if (state.kind == CallKind.VIDEO) "Incoming video call" else "Incoming voice call"
            val notif = NotificationCompat.Builder(context, INCOMING_CHANNEL)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(state.peerName)
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
        }

        fun cancelIncoming(context: Context) {
            runCatching { NotificationManagerCompat.from(context).cancel(INCOMING_ID) }
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
            if (nm.getNotificationChannel(INCOMING_CHANNEL) != null) return
            nm.createNotificationChannel(
                NotificationChannel(INCOMING_CHANNEL, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Ringing notifications for incoming calls"
                    enableVibration(true)
                    setBypassDnd(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
        }
    }
}

/** Handles Accept / Decline taps from the incoming-call notification. */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        CallManager.init(context)
        when (intent.action) {
            CallForegroundService.ACTION_ACCEPT -> {
                CallForegroundService.cancelIncoming(context)
                // Bring the app forward so the in-call UI (and camera preview) is visible.
                context.startActivity(
                    Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                )
                CallManager.accept()
            }
            CallForegroundService.ACTION_DECLINE -> {
                CallForegroundService.cancelIncoming(context)
                CallManager.decline()
            }
            // From the PiP window's RemoteActions — the only controls that fit there.
            CallForegroundService.ACTION_TOGGLE_MUTE -> CallManager.toggleMute()
            CallForegroundService.ACTION_HANGUP -> CallManager.hangup()
        }
    }
}

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

/**
 * Keeps a live location share emitting while Voiid is backgrounded (docs/LOCATION.md §5).
 *
 * Mirrors [CallForegroundService]'s trap handling: declaring `foregroundServiceType="location"`
 * on the <service> in the manifest is NECESSARY BUT NOT SUFFICIENT — on Android 14+ the type is
 * asserted at RUNTIME and the start is rejected outright unless the process holds
 * FOREGROUND_SERVICE_LOCATION *and* a location runtime grant. We degrade rather than crash: if
 * the typed start is refused we retry untyped; if even that fails, [running] stays false and the
 * engine falls back to a foreground-only share.
 *
 * The notification is ongoing, non-dismissible, LOW importance, on its own channel, and carries
 * a Stop action — the honest in-app disclosure that the app is emitting your position, and the
 * one-tap way to end it. App/Play review requires exactly this for background location.
 */
class LocationForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel(this)
        val notif = ongoingNotification(this)

        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching {
                startForeground(ONGOING_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            }.recoverCatching { startForeground(ONGOING_ID, notif) }.isSuccess
        } else {
            runCatching { startForeground(ONGOING_ID, notif) }.isSuccess
        }

        running = started
        if (!started) {
            runCatching { stopSelf() }
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away mid-share: stop cleanly. The share still ends correctly on both sides at
        // expiresAt regardless (the timer guarantee, docs/LOCATION.md §3).
        runCatching { LocationShareEngine.stopAllFromSystem() }
        running = false
        runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        runCatching { stopSelf() }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "location_share"
        private const val ONGOING_ID = 4811
        const val ACTION_STOP = "com.voiid.app.LOCATION_STOP_ALL"

        /** True while the FGS actually holds its `location` type — the engine only trusts
         *  background emission while this is set. */
        @Volatile
        var running: Boolean = false
            private set

        fun start(context: Context) {
            val i = Intent(context, LocationForegroundService::class.java)
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(i)
                else context.startService(i)
            }
        }

        fun stop(context: Context) {
            running = false
            runCatching { context.stopService(Intent(context, LocationForegroundService::class.java)) }
        }

        private fun ongoingNotification(context: Context): Notification {
            val open = Intent(context, MainActivity::class.java).apply { flags = Intent.FLAG_ACTIVITY_SINGLE_TOP }
            val pi = PendingIntent.getActivity(
                context, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val stopPi = PendingIntent.getBroadcast(
                context, 1, Intent(context, LocationActionReceiver::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setContentTitle("Sharing live location")
                .setContentText("Tap Stop to end sharing")
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setContentIntent(pi)
                .addAction(0, "Stop sharing", stopPi)
                .build()
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            if (nm.getNotificationChannel(CHANNEL) != null) return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Live location", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while you are sharing your live location in a chat"
                    setSound(null, null)
                },
            )
        }
    }
}

/** Handles the Stop-sharing action from the ongoing location notification. */
class LocationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == LocationForegroundService.ACTION_STOP) {
            LocationShareEngine.init(context.applicationContext)
            LocationShareEngine.stopAllFromSystem()
        }
    }
}

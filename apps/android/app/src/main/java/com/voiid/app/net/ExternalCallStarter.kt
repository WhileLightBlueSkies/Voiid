package com.voiid.app.net

import android.content.Context
import android.content.Intent
import com.voiid.app.MainActivity
import com.voiid.app.main.CallKind
import com.voiid.app.store.UserDirectory
import com.voiid.app.store.VoiidDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Starts a Voiid call that was initiated from OUTSIDE the app — the inbound half of
 * dialer/contact linking, and the direct port of `CallIntentRouter.swift`.
 *
 * Two entry points reach it:
 *  - [com.voiid.app.contacts.CallFromContactActivity] — the "Voice call (Voiid)" /
 *    "Video call (Voiid)" rows inside a contact card.
 *  - [CallBackActivity] — a redial from the system call log (Android 16.1+ unified VoIP
 *    call history).
 *
 * THE RULE FROM iOS, RESTATED: an affordance that does nothing when tapped is worse than
 * not offering it. So every failure path here still opens the app rather than dying
 * silently — a user who taps "Voice call (Voiid)" and gets a blank screen has learned that
 * the feature is broken, which is a much more expensive outcome than a call we couldn't
 * place.
 *
 * Runs its own IO scope because these are `Theme.NoDisplay` activities that finish
 * immediately: the directory/database lookups must outlive them.
 */
object ExternalCallStarter {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Start a call to whoever owns [rawNumber].
     *
     * The system hands back whatever string it stored — spaced, dashed, or re-formatted by
     * the dialer — so the number is normalized on BOTH sides of the comparison inside
     * [UserDirectory.userIdForPhoneBlocking]. A raw string compare here would silently fail
     * to find a user we plainly know.
     */
    fun startFromPhone(context: Context, rawNumber: String?, video: Boolean) {
        val app = context.applicationContext
        if (rawNumber.isNullOrBlank()) { openApp(app); return }
        scope.launch {
            UserDirectory.ready(app)
            val userId = UserDirectory.userIdForPhoneBlocking(rawNumber)
            if (userId == null) {
                android.util.Log.w("VOIID", "call intent for a number we don't know — opening the app")
                openApp(app)
                return@launch
            }
            place(app, userId, video)
        }
    }

    /**
     * Start a call to a known Voiid user id. Better than the iOS path, which can only ever
     * reverse-map a phone number: our own contact rows carry the peer's user id in DATA1, so
     * a tap needs no lookup at all and works even for a peer whose number was re-formatted.
     */
    fun startFromUserId(context: Context, userId: String?, video: Boolean) {
        val app = context.applicationContext
        if (userId.isNullOrBlank()) { openApp(app); return }
        scope.launch {
            UserDirectory.ready(app)
            place(app, userId, video)
        }
    }

    private suspend fun place(app: Context, userId: String, video: Boolean) {
        // Not signed in: there is no call to place. Open the app so the user lands on the
        // login screen instead of on nothing.
        if (TokenStore.get(app).jwt == null) { openApp(app); return }
        // A call started from a contact card carries a person, not a conversation. Attaching
        // the existing direct conversation (when there is one) is what puts the call in the
        // right chat's history rather than leaving it floating.
        val conversationId = runCatching {
            VoiidDatabase.get(app).conversations().idForPeer(userId)
        }.getOrNull()
        val name = UserDirectory.displayName(userId)
        withContext(Dispatchers.Main) {
            openApp(app)
            CallManager.init(app)
            CallManager.startOutgoing(
                conversationId = conversationId,
                peerUserId = userId,
                peerName = name,
                kind = if (video) CallKind.VIDEO else CallKind.VOICE,
            )
        }
    }

    /** Bring the app forward so the in-app call UI (and camera preview) is visible. */
    private fun openApp(app: Context) {
        runCatching {
            app.startActivity(
                Intent(app, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
        }
    }
}

package com.voiid.app.contacts

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.ContactsContract.Data
import androidx.core.content.ContextCompat
import com.voiid.app.net.ExternalCallStarter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * The tap target behind the "Voice call (Voiid)" / "Video call (Voiid)" rows — the Android
 * equivalent of `CallIntentRouter.swift`.
 *
 * The Contacts app fires `ACTION_VIEW` on `content://com.android.contacts/data/<id>` with
 * one of our custom MIME types. We read that single Data row back: DATA1 holds the peer's
 * Voiid user id, which the sync adapter put there precisely so this path needs no reverse
 * lookup at all. (iOS cannot do this — it only ever gets a phone number back — so this is
 * one place Android is strictly better.)
 *
 * FALLBACKS MATTER MORE THAN THE HAPPY PATH. A row that does nothing when tapped is worse
 * than not offering the affordance, so: no DATA1 -> fall back to the raw contact's phone
 * number and the reverse lookup; unknown peer or signed out -> open the app. The user must
 * always end up somewhere.
 *
 * `Theme.NoDisplay`: this is a router, not a screen. It finishes inside `onCreate` and the
 * actual call is placed on a background scope by [ExternalCallStarter].
 */
class CallFromContactActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val data = intent?.data
        // The launching app may set the type explicitly or leave it for the provider to
        // report; both spellings are in the wild, so resolve it either way.
        val declaredType = intent?.type
        val app = applicationContext
        if (data == null) {
            ExternalCallStarter.startFromUserId(app, null, video = false)   // opens the app
            finish()
            return
        }
        // The provider reads are IO; the activity is finishing immediately, so they run on an
        // application-scoped coroutine rather than being rushed onto the main thread.
        scope.launch { resolveAndCall(app, data, declaredType) }
        finish()
    }

    private fun resolveAndCall(app: Context, data: Uri, declaredType: String?) {
        val mime = declaredType ?: runCatching { app.contentResolver.getType(data) }.getOrNull()
        val video = mime == VoiidContacts.MIME_VIDEO_CALL

        if (!granted(app, Manifest.permission.READ_CONTACTS)) {
            // We wrote the row, so we could still call the peer — we just cannot read which
            // one it was. Opening the app is the honest outcome.
            ExternalCallStarter.startFromUserId(app, null, video)
            return
        }
        var userId: String? = null
        var rawContactId: Long? = null
        runCatching {
            app.contentResolver.query(
                data,
                arrayOf(Data.DATA1, Data.RAW_CONTACT_ID),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    userId = c.getString(0)?.takeIf { it.isNotBlank() }
                    rawContactId = c.getLong(1)
                }
            }
        }

        val resolvedUserId = userId
        if (resolvedUserId != null) {
            ExternalCallStarter.startFromUserId(app, resolvedUserId, video)
            return
        }
        // No user id on the row (an older row, or an OEM contacts app that handed us the
        // contact rather than the data row). Fall back to the number on the same raw contact
        // and the normalized reverse lookup — exactly what iOS has to do every time.
        val number = rawContactId?.let { phoneNumberFor(app, it) }
        if (number != null) ExternalCallStarter.startFromPhone(app, number, video)
        else ExternalCallStarter.startFromUserId(app, null, video)
    }

    private fun phoneNumberFor(app: Context, rawContactId: Long): String? {
        var number: String? = null
        runCatching {
            app.contentResolver.query(
                Data.CONTENT_URI,
                arrayOf(Phone.NUMBER),
                "${Data.RAW_CONTACT_ID} = ? AND ${Data.MIMETYPE} = ?",
                arrayOf(rawContactId.toString(), Phone.CONTENT_ITEM_TYPE),
                null,
            )?.use { c -> if (c.moveToFirst()) number = c.getString(0) }
        }
        return number
    }

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private companion object {
        /** Outlives the activity, which finishes in `onCreate`. */
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }
}

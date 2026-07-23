package com.voiid.app.contacts

import android.accounts.Account
import android.accounts.AccountManager
import android.content.ContentResolver
import android.content.Context
import android.os.Bundle
import android.provider.ContactsContract

/**
 * Creates and drives the single "Voiid" [Account] the contact-card rows hang off.
 *
 * Idempotent and cheap: safe to call from any place that knows the user is signed in.
 * Everything is wrapped — an OEM that refuses account creation, or a user who removed the
 * account from Settings, must cost us the contact rows and nothing else.
 */
object VoiidAccountManager {

    val account: Account get() = Account(VoiidContacts.ACCOUNT_NAME, VoiidContacts.ACCOUNT_TYPE)

    /**
     * Ensure the account exists and is set up to sync contacts. Returns false when the
     * platform refused — the caller should treat that as "no contact rows on this device",
     * never as an error worth interrupting the user for.
     */
    fun ensureAccount(context: Context): Boolean {
        val am = AccountManager.get(context.applicationContext) ?: return false
        val acct = account
        val exists = runCatching {
            am.getAccountsByType(VoiidContacts.ACCOUNT_TYPE).any { it.name == acct.name }
        }.getOrDefault(false)

        if (!exists) {
            // Null password / null userdata: this account holds no credentials, it exists only
            // so ContactsContract will accept RawContacts under our ACCOUNT_TYPE. See
            // [VoiidAuthenticator].
            val added = runCatching { am.addAccountExplicitly(acct, null, null) }.getOrDefault(false)
            if (!added) return false
        }

        // WRITE_SYNC_SETTINGS / READ_SYNC_SETTINGS are normal (install-time) permissions, but
        // an OEM sync-policy manager can still refuse, so both are best-effort.
        runCatching { ContentResolver.setIsSyncable(acct, ContactsContract.AUTHORITY, 1) }
        runCatching { ContentResolver.setSyncAutomatically(acct, ContactsContract.AUTHORITY, true) }
        return true
    }

    /**
     * Ask the platform to run a contacts sync now. Called after a successful
     * `contacts/discover` pass, which is the only moment new peer numbers can appear —
     * see [com.voiid.app.net.ContactsService].
     */
    fun requestSync(context: Context) {
        if (!ensureAccount(context)) return
        val extras = Bundle().apply {
            // A user-visible refresh: run it now rather than at the scheduler's convenience,
            // otherwise the rows appear minutes after the contact list already shows the peer.
            putBoolean(ContentResolver.SYNC_EXTRAS_MANUAL, true)
            putBoolean(ContentResolver.SYNC_EXTRAS_EXPEDITED, true)
        }
        runCatching { ContentResolver.requestSync(account, ContactsContract.AUTHORITY, extras) }
    }
}

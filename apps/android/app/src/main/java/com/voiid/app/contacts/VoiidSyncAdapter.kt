package com.voiid.app.contacts

import android.accounts.Account
import android.app.Service
import android.content.AbstractThreadedSyncAdapter
import android.content.ContentProviderClient
import android.content.Context
import android.content.Intent
import android.content.SyncResult
import android.os.Bundle
import android.os.IBinder

/**
 * The contacts sync adapter behind the "Voiid" account.
 *
 * It is a ONE-WAY, LOCAL sync and touches no network: everything it needs already lives in
 * the Room `users` table, populated by the on-device contact discovery in
 * [com.voiid.app.net.ContactsService]. `supportsUploading="false"` in
 * `contacts_sync_adapter.xml` says the same thing to the platform — the user's address book
 * is never read back to our servers, which is the same privacy position as the rest of
 * contact discovery (numbers are matched by SHA-256 hash and raw numbers never leave the
 * device).
 *
 * All the real work is in [VoiidContactsWriter]; this class exists because
 * `ContactsContract` will only accept RawContacts under an account type that has one.
 */
class VoiidSyncAdapter(context: Context) : AbstractThreadedSyncAdapter(context, /* autoInitialize = */ true) {

    override fun onPerformSync(
        account: Account?,
        extras: Bundle?,
        authority: String?,
        provider: ContentProviderClient?,
        syncResult: SyncResult?,
    ) {
        val outcome = runCatching { VoiidContactsWriter.sync(context) }
            .getOrElse { VoiidContactsWriter.Outcome(skipped = it.message ?: "sync threw") }

        if (outcome.skipped != null) {
            // Not an error to retry: a refused WRITE_CONTACTS prompt is a decision, and
            // hammering the scheduler over it would be worse than doing nothing.
            android.util.Log.i("VOIID", "contacts sync skipped: ${outcome.skipped}")
            return
        }
        syncResult?.stats?.numInserts = outcome.written.toLong()
        syncResult?.stats?.numDeletes = outcome.removed.toLong()
        android.util.Log.i("VOIID", "contacts sync: ${outcome.written} written, ${outcome.removed} removed")
    }
}

/**
 * Binds [VoiidSyncAdapter] for the platform's sync scheduler. Exported and protected by
 * `BIND_SYNC_ADAPTER`, so only the system can bind it.
 *
 * The adapter is a process-wide singleton per the standard AOSP pattern: the scheduler may
 * bind this service from several threads and each instance would otherwise run its own
 * concurrent batch against the contacts provider.
 */
class VoiidContactsSyncService : Service() {

    override fun onCreate() {
        super.onCreate()
        synchronized(lock) {
            if (adapter == null) adapter = VoiidSyncAdapter(applicationContext)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = adapter?.syncAdapterBinder

    companion object {
        private val lock = Any()
        private var adapter: VoiidSyncAdapter? = null
    }
}

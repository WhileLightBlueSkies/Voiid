package com.voiid.app.contacts

import android.Manifest
import android.content.ContentProviderOperation
import android.content.ContentResolver
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import android.provider.ContactsContract.AggregationExceptions
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.ContactsContract.CommonDataKinds.StructuredName
import android.provider.ContactsContract.Data
import android.provider.ContactsContract.RawContacts
import androidx.core.content.ContextCompat
import com.voiid.app.net.E164
import com.voiid.app.store.UserDirectory
import com.voiid.app.store.displayName

/**
 * Writes the "Voice call (Voiid)" / "Video call (Voiid)" rows into the user's address book.
 *
 * This is the half of contact linking that has NO iOS analogue — iOS gets the same effect
 * for free by donating an `INStartCallIntent`. On Android the only way to put a row inside
 * someone's contact card is to own a RawContact for them under our own account type and
 * hang custom-MIME `Data` rows off it, which is what this does.
 *
 * THE FIDDLIEST PART IS AGGREGATION. Our RawContact only shows up *inside* the person's
 * existing contact if the Contacts provider merges the two. Implicit merging is driven by
 * matching name + phone number and is fragile; when it fails the rows appear on a separate
 * ghost "Voiid" contact and the whole feature reads as broken. So we do both: write a
 * matching `Phone.NUMBER` (which is why a peer with no E.164 is skipped entirely rather
 * than written unlinked), AND set an explicit [AggregationExceptions] `TYPE_KEEP_TOGETHER`
 * against the device raw contact the number resolves to.
 *
 * Idempotent by `SYNC1` (the peer's Voiid user id): a re-sync updates in place, and peers
 * we no longer hold a number for have their raw contact deleted. Nothing here is the only
 * copy of anything — deleting the Voiid account in Settings removes all of it cleanly.
 */
object VoiidContactsWriter {

    /** What a sync pass did, for the log line and for the sync adapter's stats. */
    data class Outcome(
        val written: Int = 0,
        val removed: Int = 0,
        /** Non-null when the pass could not run at all (permission, provider error). */
        val skipped: String? = null,
    )

    /** ContentProvider batches are capped (~500); flush well below it, never mid-peer. */
    private const val BATCH_LIMIT = 300

    fun sync(context: Context): Outcome {
        val app = context.applicationContext
        // WRITE_CONTACTS is a runtime permission. READ_CONTACTS shares the CONTACTS group so
        // it is usually already granted, but on targetSdk 36 that must not be assumed —
        // a refused prompt means no rows, and that is a legitimate, silent end state.
        if (!granted(app, Manifest.permission.WRITE_CONTACTS)) return Outcome(skipped = "WRITE_CONTACTS not granted")
        if (!granted(app, Manifest.permission.READ_CONTACTS)) return Outcome(skipped = "READ_CONTACTS not granted")

        UserDirectory.init(app)
        // null = the DB read FAILED (not "no peers"). Abort rather than treat a transient
        // Room error as an empty roster, which would delete every Voiid raw contact below.
        val peers = UserDirectory.withPhoneNumbersBlockingOrNull()
            ?: return Outcome(skipped = "contact directory unavailable")
        val resolver = app.contentResolver

        val existing = readOwnRawContacts(resolver)
        val wanted = HashSet<String>()
        val ops = ArrayList<ContentProviderOperation>()
        var written = 0

        for (peer in peers) {
            val e164 = E164.normalize(peer.phoneE164) ?: continue
            wanted.add(peer.userId)
            val name = peer.displayName()
            val rawId = existing[peer.userId]
            if (rawId != null) updateOps(ops, rawId, peer.userId, name, e164)
            else insertOps(ops, peer.userId, name, e164)
            written++
            if (ops.size >= BATCH_LIMIT) { apply(resolver, ops); ops.clear() }
        }

        // Peers we no longer hold a number for (contact deleted, account changed). Leaving
        // them behind would offer a "call" row for someone we can no longer dial.
        var removed = 0
        for ((userId, rawId) in existing) {
            if (wanted.contains(userId)) continue
            ops.add(
                ContentProviderOperation
                    .newDelete(asSyncAdapter(RawContacts.CONTENT_URI))
                    .withSelection("${RawContacts._ID} = ?", arrayOf(rawId.toString()))
                    .build(),
            )
            removed++
            if (ops.size >= BATCH_LIMIT) { apply(resolver, ops); ops.clear() }
        }
        if (ops.isNotEmpty()) { apply(resolver, ops); ops.clear() }

        // Second pass, and it must be second: the raw contact ids of everything we just
        // inserted only exist after the batch above committed.
        linkToDeviceContacts(resolver, peers.mapNotNull { p -> E164.normalize(p.phoneE164)?.let { p.userId to it } })

        return Outcome(written = written, removed = removed)
    }

    /** Remove every trace of us from the address book (sign-out / account removal). */
    fun deleteAll(context: Context) {
        val app = context.applicationContext
        if (!granted(app, Manifest.permission.WRITE_CONTACTS)) return
        runCatching {
            app.contentResolver.delete(
                asSyncAdapter(RawContacts.CONTENT_URI),
                "${RawContacts.ACCOUNT_TYPE} = ? AND ${RawContacts.ACCOUNT_NAME} = ?",
                arrayOf(VoiidContacts.ACCOUNT_TYPE, VoiidContacts.ACCOUNT_NAME),
            )
        }
    }

    // ---- reads -----------------------------------------------------------------

    /** peer user id (`SYNC1`) -> our raw contact id. The diff key for the whole sync. */
    private fun readOwnRawContacts(resolver: ContentResolver): Map<String, Long> {
        val out = HashMap<String, Long>()
        runCatching {
            resolver.query(
                asSyncAdapter(RawContacts.CONTENT_URI),
                arrayOf(RawContacts._ID, RawContacts.SYNC1),
                "${RawContacts.ACCOUNT_TYPE} = ? AND ${RawContacts.ACCOUNT_NAME} = ? AND ${RawContacts.DELETED} = 0",
                arrayOf(VoiidContacts.ACCOUNT_TYPE, VoiidContacts.ACCOUNT_NAME),
                null,
            )?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getLong(0)
                    val sync1 = c.getString(1) ?: continue
                    out[sync1] = id
                }
            }
        }
        return out
    }

    // ---- op builders -----------------------------------------------------------

    private fun insertOps(
        ops: MutableList<ContentProviderOperation>,
        userId: String,
        name: String,
        e164: String,
    ) {
        val rawIndex = ops.size
        ops.add(
            ContentProviderOperation.newInsert(asSyncAdapter(RawContacts.CONTENT_URI))
                .withValue(RawContacts.ACCOUNT_TYPE, VoiidContacts.ACCOUNT_TYPE)
                .withValue(RawContacts.ACCOUNT_NAME, VoiidContacts.ACCOUNT_NAME)
                // SYNC1 is the diff key. It is our own user id, never anything the peer
                // controls, so a renamed contact updates instead of duplicating.
                .withValue(RawContacts.SYNC1, userId)
                .build(),
        )
        for (b in dataRows(userId, name, e164)) {
            ops.add(b.withValueBackReference(Data.RAW_CONTACT_ID, rawIndex).build())
        }
    }

    private fun updateOps(
        ops: MutableList<ContentProviderOperation>,
        rawId: Long,
        userId: String,
        name: String,
        e164: String,
    ) {
        // Replace rather than patch: there are only four rows, the peer's name or number may
        // have changed, and a wholesale rewrite cannot drift out of step with the row set.
        ops.add(
            ContentProviderOperation.newDelete(asSyncAdapter(Data.CONTENT_URI))
                .withSelection("${Data.RAW_CONTACT_ID} = ?", arrayOf(rawId.toString()))
                .build(),
        )
        for (b in dataRows(userId, name, e164)) {
            ops.add(b.withValue(Data.RAW_CONTACT_ID, rawId).build())
        }
    }

    /**
     * The four Data rows every Voiid raw contact carries.
     *
     * The name and the number are not decoration: they are what the aggregator matches on.
     * The two custom-MIME rows are the actual feature — DATA1 carries the peer's Voiid user
     * id so [CallFromContactActivity] needs no reverse lookup, DATA2 is the row's visible
     * label and DATA3 its second line (see `summaryColumn`/`detailColumn` in contacts.xml).
     */
    private fun dataRows(userId: String, name: String, e164: String): List<ContentProviderOperation.Builder> {
        val insert = { mime: String ->
            ContentProviderOperation.newInsert(asSyncAdapter(Data.CONTENT_URI))
                .withValue(Data.MIMETYPE, mime)
        }
        return listOf(
            insert(StructuredName.CONTENT_ITEM_TYPE)
                .withValue(StructuredName.DISPLAY_NAME, name),
            insert(Phone.CONTENT_ITEM_TYPE)
                .withValue(Phone.NUMBER, e164)
                .withValue(Phone.TYPE, Phone.TYPE_MOBILE),
            insert(VoiidContacts.MIME_VOICE_CALL)
                .withValue(Data.DATA1, userId)
                .withValue(Data.DATA2, VoiidContacts.LABEL_VOICE_CALL)
                .withValue(Data.DATA3, e164),
            insert(VoiidContacts.MIME_VIDEO_CALL)
                .withValue(Data.DATA1, userId)
                .withValue(Data.DATA2, VoiidContacts.LABEL_VIDEO_CALL)
                .withValue(Data.DATA3, e164),
        )
    }

    // ---- aggregation -----------------------------------------------------------

    /**
     * Force each of our raw contacts to merge into the device contact that owns the same
     * number.
     *
     * Without this the rows land on a separate "Voiid" contact roughly as often as not,
     * depending on how the user saved the number and which contacts app is installed. An
     * explicit `TYPE_KEEP_TOGETHER` exception is the only reliable answer, and it needs the
     * device raw contact id — which is what `PhoneLookup` exists to give us (it applies the
     * platform's own number-matching rules, which are strictly better than anything we would
     * hand-roll over the Phone table).
     */
    private fun linkToDeviceContacts(resolver: ContentResolver, peers: List<Pair<String, String>>) {
        if (peers.isEmpty()) return
        val ours = readOwnRawContacts(resolver)
        val ops = ArrayList<ContentProviderOperation>()
        for ((userId, e164) in peers) {
            val ourRawId = ours[userId] ?: continue
            for (deviceRawId in deviceRawContactIds(resolver, e164)) {
                ops.add(
                    ContentProviderOperation.newUpdate(AggregationExceptions.CONTENT_URI)
                        .withValue(AggregationExceptions.TYPE, AggregationExceptions.TYPE_KEEP_TOGETHER)
                        .withValue(AggregationExceptions.RAW_CONTACT_ID1, ourRawId)
                        .withValue(AggregationExceptions.RAW_CONTACT_ID2, deviceRawId)
                        .build(),
                )
            }
            if (ops.size >= BATCH_LIMIT) { apply(resolver, ops); ops.clear() }
        }
        if (ops.isNotEmpty()) apply(resolver, ops)
    }

    /** Every non-Voiid raw contact on this device holding [e164]. Usually exactly one. */
    private fun deviceRawContactIds(resolver: ContentResolver, e164: String): List<Long> {
        val contactIds = ArrayList<Long>()
        runCatching {
            val lookup = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(e164),
            )
            resolver.query(lookup, arrayOf(ContactsContract.PhoneLookup.CONTACT_ID), null, null, null)
                ?.use { c -> while (c.moveToNext()) contactIds.add(c.getLong(0)) }
        }
        if (contactIds.isEmpty()) return emptyList()

        val rawIds = ArrayList<Long>()
        for (contactId in contactIds.distinct()) {
            runCatching {
                resolver.query(
                    RawContacts.CONTENT_URI,
                    arrayOf(RawContacts._ID),
                    "${RawContacts.CONTACT_ID} = ? AND ${RawContacts.ACCOUNT_TYPE} != ?",
                    arrayOf(contactId.toString(), VoiidContacts.ACCOUNT_TYPE),
                    null,
                )?.use { c -> while (c.moveToNext()) rawIds.add(c.getLong(0)) }
            }
        }
        return rawIds.distinct()
    }

    // ---- plumbing --------------------------------------------------------------

    /**
     * `CALLER_IS_SYNCADAPTER=true` on EVERY uri. Without it the provider treats our writes as
     * user edits: it stamps them dirty, tries to sync them back through us, and refuses some
     * of the sync-only columns (`SYNC1`, hard deletes) outright.
     */
    private fun asSyncAdapter(uri: Uri): Uri = uri.buildUpon()
        .appendQueryParameter(ContactsContract.CALLER_IS_SYNCADAPTER, "true")
        .appendQueryParameter(RawContacts.ACCOUNT_NAME, VoiidContacts.ACCOUNT_NAME)
        .appendQueryParameter(RawContacts.ACCOUNT_TYPE, VoiidContacts.ACCOUNT_TYPE)
        .build()

    private fun apply(resolver: ContentResolver, ops: ArrayList<ContentProviderOperation>) {
        if (ops.isEmpty()) return
        runCatching { resolver.applyBatch(ContactsContract.AUTHORITY, ops) }
            .onFailure { android.util.Log.w("VOIID", "contacts batch failed: ${it.message}") }
    }

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}

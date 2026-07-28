package com.voiid.app.store

import android.content.Context
import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Transaction

/**
 * The single local source of truth — port of iOS `VoiidDatabase.swift` (GRDB there,
 * Room here). Everything the UI renders is read from HERE, never straight from the
 * network: the server is a sync peer, not the store.
 *
 * WHY: the conversation list only ever came from a GET, so a cold launch with no
 * network rendered an EMPTY chat grid even though the whole decrypted message history
 * sat on disk (ChatEngine's file store). Local-first fixes that class of bug by
 * construction — a failed fetch leaves the UI exactly as it was.
 *
 * The name columns are deliberately kept apart rather than pre-resolved into one
 * "display name", because precedence differs per source and each source may only write
 * the columns it owns (see [UserDirectory]).
 *
 * NO foreign keys. iOS declares `conversations.peer_user_id -> users(user_id)`; that
 * rejects the very first sync of a conversation whose peer we have never seen, which is
 * the normal case on a fresh install (see the report in the PR description).
 */
@Database(
    entities = [
        UserRow::class, ConversationRow::class, MessageRow::class, CallHistoryRow::class,
        // Location sharing (docs/LOCATION.md §6). Additive in schema v2 via MIGRATION_1_2.
        LocationShareRow::class, LocationShareTargetRow::class, LocationLastFixRow::class,
        // Stories (24h ephemeral E2EE media). Additive in schema v3 via MIGRATION_2_3 — sequenced
        // AFTER location so two concurrent table-adding features don't both own "1 -> 2".
        StoryRow::class, StoryAudienceRow::class, StoryViewRow::class,
    ],
    version = 4,
    exportSchema = false,
)
abstract class VoiidDatabase : RoomDatabase() {

    abstract fun users(): UserDao
    abstract fun conversations(): ConversationDao
    abstract fun messages(): MessageDao
    abstract fun calls(): CallHistoryDao
    abstract fun location(): LocationDao
    abstract fun stories(): StoryDao

    companion object {
        /**
         * Sign-out teardown only (see [com.voiid.app.net.SessionTeardown]) — truncates
         * EVERY table (users, conversations, messages, call_history, location + story rows)
         * in one transaction via Room's built-in [RoomDatabase.clearAllTables]. Without this
         * the next account signed in on this device would render the previous user's chats
         * and calls, because reads here are local-first (see the class doc above).
         */
        fun wipeAllForSignOut(context: Context) {
            runCatching { get(context).clearAllTables() }
        }

        @Volatile private var instance: VoiidDatabase? = null

        fun get(context: Context): VoiidDatabase =
            instance ?: synchronized(this) {
                instance ?: Room
                    .databaseBuilder(context.applicationContext, VoiidDatabase::class.java, "voiid.db")
                    // A cache that can't be opened must never be worse than no cache: a
                    // schema we can't migrate is dropped and re-synced rather than crashing
                    // the app on launch. Messages also live in ChatEngine's file store, so
                    // dropping THEM is survivable.
                    //
                    // BUT the fallback is a data-loss trap, not a free pass: it silently drops
                    // and recreates EVERY table on any version bump lacking a Migration —
                    // including `call_history` and the address-book `saved_name`/`phone_e164`
                    // columns in `users`, which are NOT recoverable from anywhere else. So
                    // every version bump from here on MUST ship an explicit additive Migration
                    // (see MIGRATION_1_2). The fallback stays only as the last-resort guard for
                    // a genuinely corrupt file.
                    .addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4)
                    .fallbackToDestructiveMigration()
                    .build()
                    .also { instance = it }
            }
    }
}

// MARK: - Rows

/**
 * One row per person we know anything about, from any source.
 *   saved_name  — from THIS device's address book. Always wins: if you saved them as
 *                 "Mum", the app says "Mum" whatever they called themselves at signup.
 *   full_name   — what the peer set on their own profile.
 *   username    — Clips handle.
 *   phone_e164  — normalized number, shown when there is no name at all.
 * A raw user id is NEVER an acceptable display name (that's the UUID bug).
 */
@Entity(tableName = "users")
data class UserRow(
    @PrimaryKey @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "saved_name") val savedName: String? = null,
    @ColumnInfo(name = "full_name") val fullName: String? = null,
    @ColumnInfo(name = "username") val username: String? = null,
    @ColumnInfo(name = "phone_e164") val phoneE164: String? = null,
    @ColumnInfo(name = "photo_url") val photoUrl: String? = null,
    @ColumnInfo(name = "bio") val bio: String? = null,
    @ColumnInfo(name = "updated_at") val updatedAt: Long = 0,
)

/**
 * `title` is only authoritative for GROUPS. A direct chat's title is derived at READ
 * time from `users` via peer_user_id, so renaming a contact in the address book updates
 * every screen at once instead of leaving a stale denormalized copy here.
 */
@Entity(
    tableName = "conversations",
    indices = [Index(value = ["last_message_at"], name = "idx_conversations_recent")],
)
data class ConversationRow(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "kind") val kind: String = "direct",
    @ColumnInfo(name = "title") val title: String? = null,
    @ColumnInfo(name = "peer_user_id") val peerUserId: String? = null,
    @ColumnInfo(name = "photo_url") val photoUrl: String? = null,
    @ColumnInfo(name = "last_message_at") val lastMessageAt: Long? = null,
    @ColumnInfo(name = "unread_count") val unreadCount: Int = 0,
    @ColumnInfo(name = "updated_at") val updatedAt: Long = 0,
    // Denormalized last-message snippet so the chat LIST renders from this table alone,
    // without loading/decoding the message store on the launch path. Kept fresh at write
    // time (ChatStore.bumpPreview -> LocalStore.updatePreview).
    @ColumnInfo(name = "last_message_preview") val lastMessagePreview: String? = null,
)

/**
 * Mirrors `ChatEngine.DecryptedMessage` so the existing file store imports losslessly.
 * `media_json` stays a JSON column: MediaRef is a stable @Serializable and giving it
 * tables of its own would buy nothing today.
 *
 * `pending` is the offline outbox — a message typed with no network is durable here
 * before the request is attempted, so it survives a restart and is retried.
 */
@Entity(
    tableName = "messages",
    indices = [
        // The hot query is "latest N messages in this conversation".
        Index(value = ["conversation_id", "created_at"], name = "idx_messages_conversation"),
        // Receipts arrive keyed by SERVER id; without this the match is a scan.
        Index(value = ["server_id"], name = "idx_messages_server_id"),
        // Drives the outbox flush on reconnect.
        Index(value = ["pending"], name = "idx_messages_pending"),
    ],
)
data class MessageRow(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "conversation_id") val conversationId: String,
    @ColumnInfo(name = "sender_id") val senderId: String,
    @ColumnInfo(name = "text") val text: String = "",
    @ColumnInfo(name = "created_at") val createdAt: Long,
    @ColumnInfo(name = "is_mine") val isMine: Boolean = false,
    @ColumnInfo(name = "pending") val pending: Boolean = false,
    @ColumnInfo(name = "failed") val failed: Boolean = false,
    @ColumnInfo(name = "server_id") val serverId: String? = null,
    @ColumnInfo(name = "delivery_status") val deliveryStatus: String? = null,
    @ColumnInfo(name = "media_json") val mediaJson: String? = null,
)

/**
 * Did not exist in any form before: calls were live signaling only, so a missed call
 * left no trace anywhere in the app once the notification went away.
 */
@Entity(
    tableName = "call_history",
    indices = [Index(value = ["started_at"], name = "idx_calls_recent")],
)
data class CallHistoryRow(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "conversation_id") val conversationId: String? = null,
    @ColumnInfo(name = "peer_user_id") val peerUserId: String? = null,
    @ColumnInfo(name = "kind") val kind: String = "voice",          // voice | video
    @ColumnInfo(name = "direction") val direction: String,          // incoming | outgoing
    @ColumnInfo(name = "outcome") val outcome: String = "missed",   // answered | missed | declined | failed
    @ColumnInfo(name = "started_at") val startedAt: Long,
    @ColumnInfo(name = "ended_at") val endedAt: Long? = null,
)

// MARK: - DAOs
//
// Every write is an INSERT-OR-IGNORE followed by a COALESCE merge, inside one
// transaction. That is the Room spelling of iOS's `ON CONFLICT DO UPDATE SET col =
// COALESCE(excluded.col, col)`: a source that knows nothing about a column passes null
// and leaves it alone, so an address-book sync can never clobber the peer's own profile
// name, and a profile refresh can never clobber the address-book name.

@Dao
abstract class UserDao {

    @Query("SELECT * FROM users")
    abstract fun all(): List<UserRow>

    /**
     * Everyone we hold a number for. Two callers, both of which run when the in-memory
     * mirror in [UserDirectory] may not exist yet: the contacts sync adapter (its own
     * process-level thread, no UI) and the reverse number -> user id lookup performed by a
     * cold process woken by a contact-card tap or a call-log redial.
     */
    @Query("SELECT * FROM users WHERE phone_e164 IS NOT NULL AND phone_e164 != ''")
    abstract fun withPhone(): List<UserRow>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    abstract fun insertIgnore(row: UserRow)

    @Query(
        """
        UPDATE users SET
            saved_name = COALESCE(:savedName, saved_name),
            phone_e164 = COALESCE(:phoneE164, phone_e164),
            updated_at = :now
        WHERE user_id = :userId
        """,
    )
    abstract fun mergeAddressBook(userId: String, savedName: String?, phoneE164: String?, now: Long)

    @Query(
        """
        UPDATE users SET
            full_name  = COALESCE(:fullName,  full_name),
            username   = COALESCE(:username,  username),
            photo_url  = COALESCE(:photoUrl,  photo_url),
            bio        = COALESCE(:bio,       bio),
            phone_e164 = COALESCE(:phoneE164, phone_e164),
            updated_at = :now
        WHERE user_id = :userId
        """,
    )
    abstract fun mergeServer(
        userId: String, fullName: String?, username: String?, photoUrl: String?,
        bio: String?, phoneE164: String?, now: Long,
    )

    /** From the device address book. Authoritative for `saved_name` + the number, nothing else. */
    @Transaction
    open fun upsertFromAddressBook(userId: String, savedName: String?, phoneE164: String?, now: Long) {
        insertIgnore(UserRow(userId = userId, savedName = savedName, phoneE164 = phoneE164, updatedAt = now))
        mergeAddressBook(userId, savedName, phoneE164, now)
    }

    /** From a server profile payload. Authoritative for the peer's own self-set fields. */
    @Transaction
    open fun upsertFromServer(
        userId: String, fullName: String?, username: String?, photoUrl: String?,
        bio: String?, phoneE164: String?, now: Long,
    ) {
        insertIgnore(
            UserRow(
                userId = userId, fullName = fullName, username = username,
                photoUrl = photoUrl, bio = bio, phoneE164 = phoneE164, updatedAt = now,
            ),
        )
        mergeServer(userId, fullName, username, photoUrl, bio, phoneE164, now)
    }

    /** Bulk address-book variant: one transaction for a whole contacts re-sync. */
    @Transaction
    open fun upsertManyFromAddressBook(entries: List<Triple<String, String?, String?>>, now: Long) {
        for ((userId, savedName, phoneE164) in entries) upsertFromAddressBook(userId, savedName, phoneE164, now)
    }
}

@Dao
abstract class ConversationDao {

    @Query("SELECT * FROM conversations ORDER BY COALESCE(last_message_at, 0) DESC")
    abstract fun recent(): List<ConversationRow>

    /** Settings -> Storage "Conversations" count — see [com.voiid.app.net.StorageProbe]. */
    @Query("SELECT COUNT(*) FROM conversations")
    abstract fun count(): Int

    /**
     * The direct conversation with a peer, if we already have one. Used by the calls started
     * from OUTSIDE the app (a contact-card row, a call-log redial): those arrive with a person,
     * never with a conversation, and a call that carries its conversation id lands in the right
     * chat's history instead of floating free.
     */
    @Query(
        """
        SELECT id FROM conversations
        WHERE peer_user_id = :peerUserId AND kind = 'direct'
        ORDER BY COALESCE(last_message_at, 0) DESC LIMIT 1
        """,
    )
    abstract fun idForPeer(peerUserId: String): String?

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    abstract fun insertIgnore(row: ConversationRow)

    /**
     * Denormalize the latest message's snippet + time onto the conversation row (creating it
     * if a message arrived before the conversation sync did). last_message_at only moves
     * forward. Drives the instant, message-store-free chat list.
     */
    @Query(
        """
        INSERT INTO conversations (id, kind, last_message_at, last_message_preview, updated_at)
        VALUES (:id, 'direct', :ts, :preview, :ts)
        ON CONFLICT(id) DO UPDATE SET
            last_message_preview = :preview,
            last_message_at      = MAX(:ts, COALESCE(last_message_at, 0)),
            updated_at           = :ts
        """,
    )
    abstract fun updatePreview(id: String, preview: String, ts: Long)

    @Query(
        """
        UPDATE conversations SET
            kind            = :kind,
            title           = COALESCE(:title, title),
            peer_user_id    = COALESCE(:peerUserId, peer_user_id),
            photo_url       = COALESCE(:photoUrl, photo_url),
            last_message_at = MAX(COALESCE(:lastMessageAt, 0), COALESCE(last_message_at, 0)),
            unread_count    = :unreadCount,
            updated_at      = :now
        WHERE id = :id
        """,
    )
    abstract fun merge(
        id: String, kind: String, title: String?, peerUserId: String?, photoUrl: String?,
        lastMessageAt: Long?, unreadCount: Int, now: Long,
    )

    /**
     * Deliberately an upsert and not a replace-all: rows the server omits (a conversation
     * created offline and not yet pushed) must survive a sync.
     */
    @Transaction
    open fun upsertAll(rows: List<ConversationRow>) {
        for (r in rows) {
            insertIgnore(r)
            merge(r.id, r.kind, r.title, r.peerUserId, r.photoUrl, r.lastMessageAt, r.unreadCount, r.updatedAt)
        }
    }
}

@Dao
abstract class MessageDao {

    @Query("SELECT * FROM messages WHERE conversation_id = :conversationId ORDER BY created_at ASC LIMIT :limit")
    abstract fun forConversation(conversationId: String, limit: Int): List<MessageRow>

    @Query("SELECT * FROM messages WHERE pending = 1 ORDER BY created_at ASC")
    abstract fun pending(): List<MessageRow>

    /** Settings -> Storage "Messages" count — see [com.voiid.app.net.StorageProbe]. */
    @Query("SELECT COUNT(*) FROM messages")
    abstract fun count(): Int

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    abstract fun insertIgnore(row: MessageRow)

    @Query(
        """
        UPDATE messages SET
            text      = :text,
            pending   = :pending,
            failed    = :failed,
            server_id = COALESCE(:serverId, server_id),
            -- Delivery state only ever moves FORWARD. A late re-sync of an older payload
            -- must not drag a "read" message back to "sent".
            delivery_status = CASE
                WHEN delivery_status = 'read' THEN 'read'
                WHEN delivery_status = 'delivered' AND :deliveryStatus = 'sent' THEN 'delivered'
                ELSE COALESCE(:deliveryStatus, delivery_status)
            END,
            media_json = COALESCE(:mediaJson, media_json)
        WHERE id = :id
        """,
    )
    abstract fun merge(
        id: String, text: String, pending: Boolean, failed: Boolean, serverId: String?,
        deliveryStatus: String?, mediaJson: String?,
    )

    @Transaction
    open fun upsertAll(rows: List<MessageRow>) {
        for (r in rows) {
            insertIgnore(r)
            merge(r.id, r.text, r.pending, r.failed, r.serverId, r.deliveryStatus, r.mediaJson)
        }
    }
}

@Dao
abstract class CallHistoryDao {

    @Query("SELECT * FROM call_history ORDER BY started_at DESC LIMIT :limit")
    abstract fun recent(limit: Int): List<CallHistoryRow>

    /** Calls in ONE conversation, oldest first — the transcript's call bubbles. */
    @Query("SELECT * FROM call_history WHERE conversation_id = :conversationId ORDER BY started_at ASC")
    abstract fun forConversation(conversationId: String): List<CallHistoryRow>

    /** Settings -> Storage "Calls logged" count — see [com.voiid.app.net.StorageProbe]. */
    @Query("SELECT COUNT(*) FROM call_history")
    abstract fun count(): Int

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    abstract fun insertIgnore(row: CallHistoryRow)

    @Query("UPDATE call_history SET outcome = :outcome, ended_at = COALESCE(:endedAt, ended_at) WHERE id = :id")
    abstract fun merge(id: String, outcome: String, endedAt: Long?)

    /** Idempotent by call id: the same call may be recorded twice (ring push, then teardown). */
    @Transaction
    open fun record(row: CallHistoryRow) {
        insertIgnore(row)
        merge(row.id, row.outcome, row.endedAt)
    }
}

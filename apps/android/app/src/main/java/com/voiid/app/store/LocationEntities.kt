package com.voiid.app.store

import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query

/**
 * Local location-share tables (Feature A — docs/LOCATION.md §6). These mirror the SERVER's
 * tiny share-existence rows plus the one piece the server never holds: the single most-recent
 * decrypted fix per (share, sender). There is NO history table, ever — exactly one row per
 * (share, sender), overwritten in place.
 *
 * Columns hold epoch SECONDS (the existing LocalStore boundary convention — the models on top
 * hold millis, or timestamps would be off by 1000×). NO foreign keys (same rationale as the
 * rest of VoiidDatabase: a share can reference a peer/conversation we have not synced yet).
 *
 * Share KEYS live in the secure store (SecurePrefs "voiid_location"), NEVER here — a raw
 * shareKey in SQLite would defeat the whole point (docs/LOCATION.md §6).
 */
@Entity(
    tableName = "location_shares",
    indices = [Index(value = ["expires_at"], name = "idx_location_shares_expiry")],
)
data class LocationShareRow(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "kind") val kind: String,                 // conversation | map
    @ColumnInfo(name = "direction") val direction: String,       // out | in
    @ColumnInfo(name = "conversation_id") val conversationId: String? = null,
    @ColumnInfo(name = "peer_user_id") val peerUserId: String? = null,   // in: owner; out: peer (1:1)
    @ColumnInfo(name = "started_at") val startedAt: Long,        // epoch seconds
    @ColumnInfo(name = "expires_at") val expiresAt: Long,        // epoch seconds
    @ColumnInfo(name = "ended_at") val endedAt: Long? = null,    // epoch seconds
    @ColumnInfo(name = "cadence_seconds") val cadenceSeconds: Int,
    @ColumnInfo(name = "state") val state: String,               // live | stale | ended
)

/** Outbound-only recipient list for a share (revocation bookkeeping). */
@Entity(tableName = "location_share_targets", primaryKeys = ["share_id", "user_id"])
data class LocationShareTargetRow(
    @ColumnInfo(name = "share_id") val shareId: String,
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "revoked_at") val revokedAt: Long? = null,  // epoch seconds
)

/** The single most-recent decrypted fix per (share, sender). Overwritten in place; no trail. */
@Entity(tableName = "location_last_fix", primaryKeys = ["share_id", "sender_user_id"])
data class LocationLastFixRow(
    @ColumnInfo(name = "share_id") val shareId: String,
    @ColumnInfo(name = "sender_user_id") val senderUserId: String,
    @ColumnInfo(name = "lat") val lat: Double,
    @ColumnInfo(name = "lon") val lon: Double,
    @ColumnInfo(name = "acc") val acc: Double,
    @ColumnInfo(name = "seq") val seq: Long,
    @ColumnInfo(name = "fixed_at") val fixedAt: Long,            // epoch seconds
)

@Dao
abstract class LocationDao {

    @Query("SELECT * FROM location_shares WHERE ended_at IS NULL ORDER BY started_at DESC")
    abstract fun activeShares(): List<LocationShareRow>

    @Query("SELECT * FROM location_shares WHERE id = :id")
    abstract fun share(id: String): LocationShareRow?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertShare(row: LocationShareRow)

    @Query("UPDATE location_shares SET ended_at = :endedAt, state = 'ended' WHERE id = :id")
    abstract fun markEnded(id: String, endedAt: Long)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertTarget(row: LocationShareTargetRow)

    @Query("UPDATE location_share_targets SET revoked_at = :revokedAt WHERE share_id = :shareId AND user_id = :userId")
    abstract fun revokeTarget(shareId: String, userId: String, revokedAt: Long)

    @Query("SELECT * FROM location_last_fix WHERE share_id = :shareId")
    abstract fun lastFix(shareId: String): LocationLastFixRow?

    /** Overwrite in place — REPLACE on the (share, sender) primary key keeps exactly one row. */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertLastFix(row: LocationLastFixRow)

    @Query("DELETE FROM location_last_fix WHERE share_id = :shareId")
    abstract fun deleteFixes(shareId: String)
}

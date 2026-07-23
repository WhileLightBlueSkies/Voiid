package com.voiid.app.store

import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Transaction

/**
 * Local storage for Stories — the 24h ephemeral, E2EE media feed.
 *
 * WHY these tables and not the ChatEngine file store: `ChatEngine.persist()` atomically
 * REWRITES the whole `voiid_messages.json` on every append. Putting stories there would be
 * quadratic write amplification against the user's entire chat history for content that is
 * deleted again within a day.
 *
 * The decrypted story PLAINTEXT never lands in this database either — only a [StoryRow.localPath]
 * pointing at a file in the app cache dir (see [StoryLocalStore]). A 50 MB video in a BLOB column
 * would be read into memory on every query that touches the row.
 *
 * TIME UNITS: every column here holds epoch SECONDS, matching `conversations.last_message_at`
 * and `call_history.started_at`. The Kotlin models hold epoch MILLIS. The conversion happens at
 * the [StoryLocalStore] boundary and NOWHERE else — getting this wrong is a 1000x timestamp bug
 * that presents as "every story is already expired" or "every story expires in the year 57000".
 *
 * NO foreign keys and NO SQL DEFAULT clauses, deliberately:
 *   - foreign keys: same reason as the rest of this database (see [VoiidDatabase]) — a story can
 *     legitimately arrive from an author whose `users` row we have not written yet.
 *   - defaults: Room validates the live schema against what it would have generated, and a
 *     DEFAULT present on one side only is a migration crash on app launch. Kotlin's constructor
 *     defaults below give exactly the same behaviour with none of that risk, because every write
 *     path inserts a fully-constructed row.
 */

/**
 * One story. Both OURS ([isMine]) and other people's live here — the viewer pages across
 * everything and a single table keeps the expiry sweep to one statement.
 *
 * `media_json` is a [com.voiid.app.net.ChatEngine.MediaRef] verbatim, the same convention as
 * `messages.media_json`, and it carries the AES-256-GCM media key. That key NEVER goes to the
 * server; it arrived inside a Double Ratchet ciphertext and it stops here.
 */
@Entity(
    tableName = "stories",
    indices = [
        // The tray groups by author, newest-first — the only listing query there is.
        Index(value = ["author_id", "created_at"], name = "idx_stories_author_created"),
        // Drives the local expiry sweep on every foreground.
        Index(value = ["expires_at"], name = "idx_stories_expires"),
    ],
)
data class StoryRow(
    @PrimaryKey @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "author_id") val authorId: String,
    @ColumnInfo(name = "is_mine") val isMine: Boolean = false,
    /** Epoch SECONDS. */
    @ColumnInfo(name = "created_at") val createdAt: Long,
    /** Epoch SECONDS. Server-computed `created_at + 24h`; the envelope's claim is only a fallback. */
    @ColumnInfo(name = "expires_at") val expiresAt: Long,
    /** `MediaRef` JSON — object key + media key + nonce + ciphertext hash. */
    @ColumnInfo(name = "media_json") val mediaJson: String,
    @ColumnInfo(name = "caption") val caption: String = "",
    @ColumnInfo(name = "duration_ms") val durationMs: Long? = null,
    @ColumnInfo(name = "width") val width: Int? = null,
    @ColumnInfo(name = "height") val height: Int? = null,
    @ColumnInfo(name = "allows_replies") val allowsReplies: Boolean = true,
    /**
     * Epoch SECONDS, NULL = unseen. Drives the seen/unseen ring.
     * NEVER TRANSMITTED. Telling the server when you opened a story is exactly the fact a
     * view receipt exists to volunteer, and it is opt-in (see [com.voiid.app.net.StoryEngine]).
     */
    @ColumnInfo(name = "viewed_at") val viewedAt: Long? = null,
    /** Decrypted plaintext file in the app cache dir. Never the bytes themselves. */
    @ColumnInfo(name = "local_path") val localPath: String? = null,
    /** none | downloading | ready | failed | gone */
    @ColumnInfo(name = "download_state") val downloadState: String = "none",
    /**
     * OUR outgoing story only: none | uploading | sent | failed.
     * Optimistic post — the story is in "Your story" the instant Share is tapped, so a 50 MB
     * upload never blocks the UI, and a failure is a Retry affordance rather than a lost post.
     */
    @ColumnInfo(name = "upload_state") val uploadState: String = "none",
)

/**
 * The audience of one of OUR stories. AUTHOR-SIDE ONLY — this never leaves the device and there
 * is no endpoint that would accept it.
 *
 * HONEST NOTE, and it must not be softened anywhere in the UI: the server learns the audience
 * anyway. `story_keys` holds one row per recipient DEVICE and `devices.user_id` maps each back to
 * a person, so the server can enumerate exactly who a story was sent to. There is no sealed
 * sender in Voiid and one cannot be added. This table exists because the CLIENT needs the list
 * (to validate replies and to re-send keys to devices that were skipped), not as a privacy
 * measure.
 */
@Entity(tableName = "story_audience", primaryKeys = ["story_id", "user_id"])
data class StoryAudienceRow(
    @ColumnInfo(name = "story_id") val storyId: String,
    @ColumnInfo(name = "user_id") val userId: String,
)

/**
 * Who viewed one of OUR stories, decrypted from inbound view receipts. AUTHOR-SIDE ONLY.
 * Receipts fan out to ALL of the author's devices, so this list syncs across linked devices
 * for free without any extra sync path.
 */
@Entity(tableName = "story_views", primaryKeys = ["story_id", "viewer_user_id"])
data class StoryViewRow(
    @ColumnInfo(name = "story_id") val storyId: String,
    @ColumnInfo(name = "viewer_user_id") val viewerUserId: String,
    /** Epoch SECONDS. */
    @ColumnInfo(name = "viewed_at") val viewedAt: Long,
)

/**
 * Every write is INSERT-OR-IGNORE followed by a COALESCE merge inside one transaction — the
 * house idiom (see [UserDao]). It matters more here than anywhere else: the feed sync and the
 * download worker both write the same row, and a sync must never clobber a `local_path` the
 * downloader just wrote, nor a `viewed_at` the viewer just set.
 */
@Dao
abstract class StoryDao {

    /** Every unexpired story, newest-first. [nowSeconds] is passed in so the filter is testable
     *  and so the query is not at the mercy of SQLite's clock. */
    @Query("SELECT * FROM stories WHERE expires_at > :nowSeconds ORDER BY created_at DESC")
    abstract fun live(nowSeconds: Long): List<StoryRow>

    @Query("SELECT * FROM stories WHERE id = :id")
    abstract fun byId(id: String): StoryRow?

    /** Rows the local sweep must drop, so their cached plaintext files can be deleted too. */
    @Query("SELECT * FROM stories WHERE expires_at <= :nowSeconds")
    abstract fun expired(nowSeconds: Long): List<StoryRow>

    @Query("DELETE FROM stories WHERE expires_at <= :nowSeconds")
    abstract fun deleteExpired(nowSeconds: Long)

    @Query("DELETE FROM stories WHERE id = :id")
    abstract fun delete(id: String)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    abstract fun insertIgnore(row: StoryRow)

    /**
     * A re-sync knows the story's identity and metadata but knows NOTHING about this device's
     * local state, so it passes null for those and COALESCE leaves them alone. `viewed_at` and
     * `local_path` in particular are per-device facts that no server payload can carry.
     */
    @Query(
        """
        UPDATE stories SET
            media_json     = :mediaJson,
            caption        = :caption,
            duration_ms    = COALESCE(:durationMs, duration_ms),
            width          = COALESCE(:width, width),
            height         = COALESCE(:height, height),
            allows_replies = :allowsReplies,
            expires_at     = :expiresAt,
            viewed_at      = COALESCE(:viewedAt, viewed_at),
            local_path     = COALESCE(:localPath, local_path),
            download_state = COALESCE(:downloadState, download_state),
            upload_state   = COALESCE(:uploadState, upload_state)
        WHERE id = :id
        """,
    )
    abstract fun merge(
        id: String, mediaJson: String, caption: String, durationMs: Long?, width: Int?, height: Int?,
        allowsReplies: Boolean, expiresAt: Long, viewedAt: Long?, localPath: String?,
        downloadState: String?, uploadState: String?,
    )

    @Transaction
    open fun upsert(row: StoryRow) {
        insertIgnore(row)
        merge(
            row.id, row.mediaJson, row.caption, row.durationMs, row.width, row.height,
            row.allowsReplies, row.expiresAt, row.viewedAt, row.localPath,
            row.downloadState.takeIf { it != "none" }, row.uploadState.takeIf { it != "none" },
        )
    }

    @Transaction
    open fun upsertAll(rows: List<StoryRow>) { for (r in rows) upsert(r) }

    /** Local-only. Idempotent: the first open wins, so re-opening doesn't re-fire a receipt. */
    @Query("UPDATE stories SET viewed_at = :atSeconds WHERE id = :id AND viewed_at IS NULL")
    abstract fun markViewed(id: String, atSeconds: Long)

    @Query("UPDATE stories SET local_path = :path, download_state = :state WHERE id = :id")
    abstract fun setDownload(id: String, path: String?, state: String)

    @Query("UPDATE stories SET upload_state = :state WHERE id = :id")
    abstract fun setUpload(id: String, state: String)

    // MARK: - Audience (author-side only)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    abstract fun insertAudience(rows: List<StoryAudienceRow>)

    @Query("SELECT user_id FROM story_audience WHERE story_id = :storyId")
    abstract fun audience(storyId: String): List<String>

    @Query("DELETE FROM story_audience WHERE story_id = :storyId")
    abstract fun deleteAudience(storyId: String)

    /** Orphans left behind when a story row is swept (no FK cascade in this database). */
    @Query("DELETE FROM story_audience WHERE story_id NOT IN (SELECT id FROM stories)")
    abstract fun pruneAudience()

    // MARK: - Viewers (author-side only)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    abstract fun insertView(row: StoryViewRow)

    @Query("SELECT * FROM story_views WHERE story_id = :storyId ORDER BY viewed_at DESC")
    abstract fun views(storyId: String): List<StoryViewRow>

    @Query("SELECT COUNT(*) FROM story_views WHERE story_id = :storyId")
    abstract fun viewCount(storyId: String): Int

    @Query("DELETE FROM story_views WHERE story_id NOT IN (SELECT id FROM stories)")
    abstract fun pruneViews()
}

package com.voiid.app.store

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * Room migration 2 -> 3: adds the Stories tables and NOTHING else.
 *
 * VERSIONING NOTE — this is 2 -> 3, not 1 -> 2, because the Location-sharing work concurrently
 * claimed `version = 2` / `MIGRATION_1_2` (see [Migrations].`MIGRATION_1_2`) for its own tables.
 * Two additive features that each add tables must be SEQUENCED, not both own "1 -> 2": v1 core ->
 * v2 location -> v3 stories. A fresh install builds v3 directly; an existing v1 user runs both
 * migrations in order; an existing v2 user runs only this one.
 *
 * WHY A REAL MIGRATION AT ALL — the database shipped at `version = 1` with
 * `.fallbackToDestructiveMigration()` and ZERO migrations. Bumping the version to add tables
 * WITHOUT a real migration silently DROPS AND RECREATES every table, and `call_history` plus the
 * address-book `users.saved_name` / `users.phone_e164` columns are NOT recoverable from anywhere.
 * This migration is the safe path; the destructive fallback stays only as a last resort.
 *
 * IT TOUCHES NO EXISTING TABLE. Only `CREATE TABLE IF NOT EXISTS` + `CREATE INDEX IF NOT EXISTS`.
 *
 * The SQL below must stay schema-compatible with the [StoryRow] / [StoryAudienceRow] /
 * [StoryViewRow] entities. Room validates the live schema against what it would have generated
 * for those entities the first time the DB is opened at v3, and — because a migration path now
 * exists — a mismatch is an IllegalStateException at launch, NOT a silent destructive rebuild.
 * That is why: column types are the Room affinities (TEXT / INTEGER), non-null Kotlin properties
 * are `NOT NULL`, nullable ones are not, there are NO DEFAULT clauses (the entities declare none —
 * Kotlin constructor defaults are not SQL defaults), and the index names/columns match the
 * `@Index(name = ...)` declarations exactly.
 */
val MIGRATION_2_3 = object : Migration(2, 3) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS `stories` (
                `id` TEXT NOT NULL,
                `author_id` TEXT NOT NULL,
                `is_mine` INTEGER NOT NULL,
                `created_at` INTEGER NOT NULL,
                `expires_at` INTEGER NOT NULL,
                `media_json` TEXT NOT NULL,
                `caption` TEXT NOT NULL,
                `duration_ms` INTEGER,
                `width` INTEGER,
                `height` INTEGER,
                `allows_replies` INTEGER NOT NULL,
                `viewed_at` INTEGER,
                `local_path` TEXT,
                `download_state` TEXT NOT NULL,
                `upload_state` TEXT NOT NULL,
                PRIMARY KEY(`id`)
            )
            """.trimIndent(),
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS `idx_stories_author_created` ON `stories` (`author_id`, `created_at`)")
        db.execSQL("CREATE INDEX IF NOT EXISTS `idx_stories_expires` ON `stories` (`expires_at`)")

        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS `story_audience` (
                `story_id` TEXT NOT NULL,
                `user_id` TEXT NOT NULL,
                PRIMARY KEY(`story_id`, `user_id`)
            )
            """.trimIndent(),
        )

        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS `story_views` (
                `story_id` TEXT NOT NULL,
                `viewer_user_id` TEXT NOT NULL,
                `viewed_at` INTEGER NOT NULL,
                PRIMARY KEY(`story_id`, `viewer_user_id`)
            )
            """.trimIndent(),
        )
    }
}

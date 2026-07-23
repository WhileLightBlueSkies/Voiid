package com.voiid.app.store

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/**
 * The app's FIRST Room migration (own file so future ones just append).
 *
 * WHY THIS IS MANDATORY, NOT OPTIONAL: VoiidDatabase keeps `.fallbackToDestructiveMigration()`
 * (a corrupt cache must never be worse than no cache). But that fallback fires on ANY version
 * bump with no matching Migration — and it does not crash, it silently DROPS AND RECREATES
 * EVERY TABLE. That would destroy `call_history` and the address-book `saved_name`/`phone_e164`
 * columns in `users`, none of which are recoverable from ChatEngine's file store. So every
 * version bump from here on MUST ship a Migration. This one is purely additive: it only
 * CREATE TABLE IF NOT EXISTS + CREATE INDEX for the location tables and touches nothing else,
 * so no existing row is ever at risk.
 *
 * The statements below are written to match Room's own generated schema for
 * [LocationShareRow] / [LocationShareTargetRow] / [LocationLastFixRow] exactly (column order,
 * TEXT/INTEGER/REAL affinity, NOT NULL, primary keys, index name) — Room validates the live
 * schema against the entities on open, and a mismatch throws.
 */
val MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `location_shares` (" +
                "`id` TEXT NOT NULL, " +
                "`kind` TEXT NOT NULL, " +
                "`direction` TEXT NOT NULL, " +
                "`conversation_id` TEXT, " +
                "`peer_user_id` TEXT, " +
                "`started_at` INTEGER NOT NULL, " +
                "`expires_at` INTEGER NOT NULL, " +
                "`ended_at` INTEGER, " +
                "`cadence_seconds` INTEGER NOT NULL, " +
                "`state` TEXT NOT NULL, " +
                "PRIMARY KEY(`id`))",
        )
        db.execSQL(
            "CREATE INDEX IF NOT EXISTS `idx_location_shares_expiry` ON `location_shares` (`expires_at`)",
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `location_share_targets` (" +
                "`share_id` TEXT NOT NULL, " +
                "`user_id` TEXT NOT NULL, " +
                "`revoked_at` INTEGER, " +
                "PRIMARY KEY(`share_id`, `user_id`))",
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `location_last_fix` (" +
                "`share_id` TEXT NOT NULL, " +
                "`sender_user_id` TEXT NOT NULL, " +
                "`lat` REAL NOT NULL, " +
                "`lon` REAL NOT NULL, " +
                "`acc` REAL NOT NULL, " +
                "`seq` INTEGER NOT NULL, " +
                "`fixed_at` INTEGER NOT NULL, " +
                "PRIMARY KEY(`share_id`, `sender_user_id`))",
        )
    }
}

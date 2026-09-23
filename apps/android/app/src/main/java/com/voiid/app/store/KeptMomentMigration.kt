package com.voiid.app.store

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

/** Opt-in, author-only retention. Existing moments keep their original expiry behavior. */
val MIGRATION_6_7 = object : Migration(6, 7) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE stories ADD COLUMN kept INTEGER NOT NULL DEFAULT 0")
    }
}

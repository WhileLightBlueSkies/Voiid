package com.voiid.app

import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * A04 — a version bump must not be able to delete somebody's history.
 *
 * THE TRAP. `fallbackToDestructiveMigration()` was enabled ALONGSIDE explicit migrations, and
 * the comment above it already described the danger accurately: it silently drops and recreates
 * EVERY table on any version bump that lacks a Migration, including `call_history` and the
 * address-book `saved_name`/`phone_e164` columns on `users`, which exist nowhere else. So the
 * failure mode is not "the app crashes on upgrade" — it is "the upgrade succeeds and the user's
 * call history is gone", with nothing anywhere reporting it.
 *
 * That is a policy risk rather than a live defect: versions 1→4 all have migrations today. It
 * becomes a defect the first time somebody bumps `version` and forgets, which is exactly the
 * mistake a destructive fallback exists to hide.
 *
 * `exportSchema = false` is the other half. Without exported schemas there is no historical
 * record to migrate FROM, so no test can verify an upgrade path against what shipped — every
 * migration is checked only against the current code's idea of the old schema.
 */
class RoomMigrationPolicyTest {

    private fun moduleDir(): File {
        var dir = File(System.getProperty("user.dir")!!)
        while (!File(dir, "src/main/java").isDirectory) {
            dir = dir.parentFile ?: error("could not locate the app module")
        }
        return dir
    }

    private fun databaseSource(): String =
        File(moduleDir(), "src/main/java/com/voiid/app/store/VoiidDatabase.kt").readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines().filterNot { it.trim().startsWith("//") || it.trim().startsWith("*") }
            .joinToString("\n")

    @Test
    fun `the destructive fallback is gone`() {
        assertTrue(
            "fallbackToDestructiveMigration() drops and recreates every table on any version " +
                "bump that lacks a Migration. call_history and the address-book columns on users " +
                "are recoverable from nowhere, so this turns a forgotten migration into silent " +
                "data loss on upgrade.",
            !databaseSource().contains("fallbackToDestructiveMigration")
        )
    }

    @Test
    fun `schemas are exported, so an upgrade can be tested against what shipped`() {
        assertTrue(
            "exportSchema must be true: without the exported JSON there is no record of the " +
                "schema that shipped, and a migration can only ever be checked against the " +
                "current code's idea of the old one.",
            Regex("""exportSchema\s*=\s*true""").containsMatchIn(databaseSource())
        )
    }

    @Test
    fun `every version from 1 to the current one has a migration`() {
        val source = databaseSource()
        val version = Regex("""version\s*=\s*(\d+)""").find(source)?.groupValues?.get(1)?.toInt()
            ?: error("could not read the database version")
        val declared = Regex("""MIGRATION_(\d+)_(\d+)""").findAll(source)
            .map { it.groupValues[1].toInt() to it.groupValues[2].toInt() }
            .toSet()
        val missing = (1 until version).filter { (it to it + 1) !in declared }
        assertEquals(
            "no migration declared for these upgrades, and without the destructive fallback the " +
                "app will now refuse to open rather than quietly wiping the database — which is " +
                "the correct failure, but it has to be fixed before release",
            emptyList<Int>(), missing
        )
    }

    @Test
    fun `the exported schema for the current version is committed`() {
        val source = databaseSource()
        val version = Regex("""version\s*=\s*(\d+)""").find(source)?.groupValues?.get(1)?.toInt()!!
        val schemaFile = File(moduleDir(), "schemas/com.voiid.app.store.VoiidDatabase/$version.json")
        assertTrue(
            "schemas/…/$version.json is missing. Room writes it at build time; it must be " +
                "committed, or the next person has nothing to migrate from.",
            schemaFile.isFile
        )
        // A schema Room wrote always names its own version and the entities it covers.
        val text = schemaFile.readText()
        assertTrue("the exported schema does not declare version $version", text.contains("\"version\": $version"))
        for (table in listOf("users", "conversations", "messages", "call_history")) {
            assertTrue("the exported schema is missing the $table table", text.contains("\"tableName\": \"$table\""))
        }
    }

    /**
     * The columns the destructive fallback would have destroyed, named so a future edit that
     * drops one has to argue with this list rather than with nobody.
     */
    @Test
    fun `the irrecoverable columns are still declared`() {
        val version = Regex("""version\s*=\s*(\d+)""").find(databaseSource())?.groupValues?.get(1)!!
        val schema = File(moduleDir(), "schemas/com.voiid.app.store.VoiidDatabase/$version.json").readText()
        for (column in listOf("saved_name", "phone_e164")) {
            assertTrue(
                "`$column` is address-book data that exists on this device and nowhere else — " +
                    "it cannot be re-synced from the server.",
                schema.contains("\"columnName\": \"$column\"")
            )
        }
        assertTrue("call_history is local-only and unrecoverable", schema.contains("\"tableName\": \"call_history\""))
    }
}

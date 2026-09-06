package com.voiid.app

import com.voiid.app.net.SecurePrefsPolicy
import com.voiid.app.net.SecurePrefsPolicy.Action
import com.voiid.app.net.SecurePrefsPolicy.Failure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.KeyStoreException
import java.security.GeneralSecurityException
import javax.crypto.AEADBadTagException

/**
 * A02 — what happens when an encrypted preference store will not open.
 *
 * THE BUG THIS PINS. The old handler had one response to every failure: delete the preference
 * file. If the rebuild then failed it deleted the ANDROID KEYSTORE MASTER KEY — the single key
 * shared by every store in the app. So a transient storage error, a device that happened to be
 * locked, or one corrupted file could destroy the E2E identity, the session token, the message
 * history AND the account-backup master secret, all at once, silently, on launch.
 *
 * The failures are not interchangeable and the responses must not be either. A locked device
 * is temporary and destroying data because of it is absurd. An invalidated key is permanent
 * but its consequence is the user's to accept, not ours to assume. Only genuinely corrupted
 * ciphertext justifies putting a file aside — and aside, not away.
 */
class SecurePrefsRecoveryTest {

    // ── Classification ───────────────────────────────────────────────────────────

    @Test
    fun `a locked device is recognised as temporary, not as damage`() {
        assertEquals(Failure.DEVICE_LOCKED,
            SecurePrefsPolicy.classify(KeyStoreException("Key user not authenticated")))
        assertEquals(Failure.DEVICE_LOCKED,
            SecurePrefsPolicy.classify(IllegalStateException("user not authenticated")))
    }

    @Test
    fun `an invalidated key is recognised as permanent`() {
        assertEquals(Failure.KEY_INVALIDATED,
            SecurePrefsPolicy.classify(GeneralSecurityException("Key permanently invalidated")))
    }

    @Test
    fun `unreadable ciphertext is recognised as corruption`() {
        assertEquals(Failure.CORRUPTED, SecurePrefsPolicy.classify(AEADBadTagException("tag mismatch")))
        assertEquals(Failure.CORRUPTED,
            SecurePrefsPolicy.classify(IOException("invalid keyset: cannot parse")))
    }

    @Test
    fun `a failure nobody anticipated is not guessed at`() {
        assertEquals(Failure.UNKNOWN, SecurePrefsPolicy.classify(RuntimeException("something new")))
        // The cause chain is searched, because androidx wraps liberally.
        assertEquals(Failure.CORRUPTED,
            SecurePrefsPolicy.classify(RuntimeException("open failed", AEADBadTagException())))
    }

    // ── The decision table, which is the whole fix ───────────────────────────────

    @Test
    fun `a locked device is retried and then reported, never wiped`() {
        assertEquals(Action.RETRY, SecurePrefsPolicy.decide(Failure.DEVICE_LOCKED, attempt = 1))
        assertEquals(Action.RETRY, SecurePrefsPolicy.decide(Failure.DEVICE_LOCKED, attempt = 2))
        // It gives up by SAYING SO, not by deleting the user's identity.
        assertEquals(Action.REPORT_UNAVAILABLE,
            SecurePrefsPolicy.decide(Failure.DEVICE_LOCKED, attempt = SecurePrefsPolicy.MAX_ATTEMPTS))
    }

    @Test
    fun `an invalidated key needs an explicit reset, never a silent regeneration`() {
        for (attempt in 1..SecurePrefsPolicy.MAX_ATTEMPTS) {
            assertEquals(
                "regenerating identity because a key expired is a decision for the user",
                Action.REPORT_UNAVAILABLE, SecurePrefsPolicy.decide(Failure.KEY_INVALIDATED, attempt)
            )
        }
    }

    @Test
    fun `corrupted ciphertext remains unavailable until explicit recovery`() {
        assertEquals(Action.REPORT_UNAVAILABLE,
            SecurePrefsPolicy.decide(Failure.CORRUPTED, attempt = 1))
    }

    @Test
    fun `an unknown failure never takes a destructive path`() {
        for (attempt in 1..SecurePrefsPolicy.MAX_ATTEMPTS) {
            assertEquals(
                "the old code guessed here, and its guess was to delete everything",
                Action.REPORT_UNAVAILABLE, SecurePrefsPolicy.decide(Failure.UNKNOWN, attempt)
            )
        }
    }

    @Test
    fun `no failure at all leads to deleting the shared master key`() {
        val actions = Failure.values().flatMap { f ->
            (1..SecurePrefsPolicy.MAX_ATTEMPTS + 2).map { SecurePrefsPolicy.decide(f, it) }
        }
        assertTrue(
            "every action must be retry, quarantine or report — there is no destructive one left",
            actions.all { it == Action.RETRY || it == Action.REPORT_UNAVAILABLE }
        )
    }

    // ── Quarantine, not deletion ─────────────────────────────────────────────────

    @Test
    fun `a quarantined file keeps its store name and cannot collide with an earlier one`() {
        val first = SecurePrefsPolicy.quarantineName("voiid_e2e", at = 1_700_000_000_000)
        val second = SecurePrefsPolicy.quarantineName("voiid_e2e", at = 1_700_000_001_000)
        assertTrue("the store it came from must stay legible", first.contains("voiid_e2e"))
        assertNotEquals("a second quarantine must not overwrite the first evidence", first, second)
        assertTrue(first.endsWith(".xml"))
    }

    /**
     * THE GUARD, and the reason A02 exists at all.
     *
     * `MasterKey.DEFAULT_MASTER_KEY_ALIAS` is shared by every encrypted store in the app.
     * Deleting it does not reset one store, it invalidates all of them — so the recovery path
     * for one unreadable file destroyed the E2E identity and the backup master secret too.
     * There is no code path that may do this automatically, and the cheapest way to keep it
     * that way is to fail the build if the call comes back.
     */
    @Test
    fun `SecurePrefs contains no automatic master-key deletion`() {
        var dir = File(System.getProperty("user.dir")!!)
        while (!File(dir, "src/main/java").isDirectory) {
            dir = dir.parentFile ?: error("could not locate the app module")
        }
        val source = File(dir, "src/main/java/com/voiid/app/net/SecurePrefs.kt").readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines().filterNot { it.trim().startsWith("//") }.joinToString("\n")

        assertTrue(
            "SecurePrefs must never delete the shared Keystore master key: it is not this " +
                "store's key, it is every store's key, and dropping it is a full identity wipe.",
            !source.contains("deleteEntry")
        )
        assertTrue(
            "SecurePrefs must never delete a preference store outright — quarantine keeps the " +
                "ciphertext so an explicit reset stays the user's decision and the evidence survives.",
            !source.contains("deleteSharedPreferences")
        )
    }
}

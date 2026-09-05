package com.voiid.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A01 — what Android is allowed to copy off this device.
 *
 * THE BUG THIS PINS. The backup rules named three encrypted preference files and one JSON
 * file, and the app had accumulated a dozen more stores since — including `voiid_recovery`,
 * which holds the base64 master secret for the encrypted account backup. Anything not named
 * was backed up to Google's cloud and copied on device transfer.
 *
 * ── WHY THIS IS A TEST AND NOT A CODE REVIEW ─────────────────────────────────────
 *
 * The failure mode is not "somebody wrote the wrong rule". It is "somebody added a store and
 * did not think about the rules", which is invisible in the diff that adds the store. So this
 * reads the SHIPPED xml and the SHIPPED sources, and fails the build when a preference store
 * appears in the code that no one has classified. Adding a store now forces the decision.
 *
 * ── THE POLICY ───────────────────────────────────────────────────────────────────
 *
 * Allowlist, not denylist. Both rule files list what MAY leave the device and nothing else,
 * so a store added tomorrow is excluded by construction rather than by remembering.
 */
class BackupRulesTest {

    /**
     * The only things that may leave this device through Android's backup or transfer.
     *
     * Cosmetic, per-install and worthless to anyone else. Nothing here identifies a person,
     * carries a message, or is wrapped by a Keystore key that cannot travel with it.
     */
    private val portable = setOf(
        "voiid_appearance",   // light/dark choice
        "voiid_prefs",        // chat layout (bubble style)
        "voiid_game_settings",
        "voiid_game_audio",
    )

    /**
     * Everything else, and WHY each one must never be copied. Kept as prose because the
     * audience for this list is the next person deciding whether their new store belongs
     * above or below this line.
     */
    private val private = mapOf(
        // ── Keystore-wrapped. The master key never leaves the device, so a restored copy is
        // undecryptable ciphertext that crashes the app on launch — and is a data leak if it
        // ever were decryptable.
        "voiid_auth" to "session token",
        "voiid_e2e" to "E2E identity and Olm sessions",
        "voiid_chat" to "message plaintext",
        "voiid_recovery" to "the account backup master secret",
        "voiid_location" to "live location share keys",
        "voiid_map" to "map presence keys",
        "voiid_map_inbound_keys" to "inbound map share keys",
        "voiid_mls" to "group messaging state",
        "voiid_profile_keys" to "profile photo keys",
        "ludo_cache" to "in-progress match state",
        // ── Plaintext prefs holding personal data.
        "voiid_contact_directory" to "the user's address book",
        "voiid_consent" to "consent records",
        "voiid_privacy_prefs" to "privacy choices",
        "voiid_story_prefs" to "story state",
        "voiid_story_engine" to "story state",
        "voiid_flags" to "per-account flags",
        // ── Local game state. Not sensitive, but per-install and meaningless elsewhere.
        "voiid.games" to "local game state",
        "voiid_bot_scores" to "local scores",
        "voiid_snake_choice" to "local game choice",
        "voiid_snake_records" to "local records",
    )

    private fun moduleDir(): File {
        var dir = File(System.getProperty("user.dir")!!)
        while (!File(dir, "src/main/res/xml").isDirectory) {
            dir = dir.parentFile ?: error("could not locate the app module from ${System.getProperty("user.dir")}")
        }
        return dir
    }

    /** The rule file with XML comments stripped: prose about the policy is not the policy. */
    private fun rules(name: String): String =
        File(moduleDir(), "src/main/res/xml/$name").readText()
            .replace(Regex("<!--.*?-->", RegexOption.DOT_MATCHES_ALL), "")

    /** Every `path="..."` inside an `<include .../>` element. */
    private fun included(xml: String): List<String> =
        Regex("""<include\b[^>]*>""").findAll(xml).map { it.value }.toList()
            .mapNotNull { Regex("""path="([^"]+)"""").find(it)?.groupValues?.get(1) }

    private fun includeDomains(xml: String): List<String> =
        Regex("""<include\b[^>]*>""").findAll(xml).map { it.value }.toList()
            .mapNotNull { Regex("""domain="([^"]+)"""").find(it)?.groupValues?.get(1) }

    @Test
    fun `both rule files allowlist rather than denylist`() {
        for (file in listOf("backup_rules.xml", "data_extraction_rules.xml")) {
            val xml = rules(file)
            assertTrue(
                "$file must use <include> — a denylist silently ships every store nobody remembered",
                included(xml).isNotEmpty()
            )
            assertTrue(
                "$file must not use <exclude>: mixing the two makes the policy unreadable, and " +
                    "with an allowlist every exclusion is already implied",
                !xml.contains("<exclude")
            )
        }
    }

    @Test
    fun `device transfer is allowlisted too, not just cloud backup`() {
        val xml = rules("data_extraction_rules.xml")
        val transfer = xml.substringAfter("<device-transfer>").substringBefore("</device-transfer>")
        assertTrue("device-transfer must carry its own allowlist", included(transfer).isNotEmpty())
        assertTrue("device-transfer must not exclude-list", !transfer.contains("<exclude"))
    }

    @Test
    fun `only the documented portable preferences may leave the device`() {
        for (file in listOf("backup_rules.xml", "data_extraction_rules.xml")) {
            val allowed = included(rules(file)).map { it.removeSuffix(".xml") }.toSet()
            assertEquals(
                "$file allows something that is not on the portable list",
                emptySet<String>(), allowed - portable
            )
        }
    }

    @Test
    fun `no private store is ever allowlisted`() {
        for (file in listOf("backup_rules.xml", "data_extraction_rules.xml")) {
            val allowed = included(rules(file)).map { it.removeSuffix(".xml") }.toSet()
            for (name in private.keys) {
                assertTrue(
                    "$file allows '$name' (${private[name]}) to leave the device",
                    name !in allowed
                )
            }
        }
    }

    @Test
    fun `only shared preferences are portable - never files, databases or caches`() {
        for (file in listOf("backup_rules.xml", "data_extraction_rules.xml")) {
            val domains = includeDomains(rules(file)).toSet()
            assertEquals(
                "$file allows a non-sharedpref domain. The Room database (voiid.db), the message " +
                    "shards in files/messages/ and the decrypted media in files/media/ are all " +
                    "private, and no file or database is portable.",
                setOf("sharedpref"), domains
            )
        }
    }

    /**
     * THE GUARD. Every preference store the code actually opens must be classified above.
     *
     * This is what makes the fix durable: `voiid_recovery` was added long after the rules were
     * written and nothing noticed. Now the build stops until someone decides.
     */
    @Test
    fun `every preference store in the source is classified as portable or private`() {
        val sources = File(moduleDir(), "src/main/java").walkTopDown().filter { it.extension == "kt" }
        val found = sortedSetOf<String>()
        val literal = Regex("""(?:SecurePrefs\.open|getSharedPreferences)\s*\([^)]*?"([A-Za-z0-9_.]+)"""")
        // Stores whose name is behind a constant: collect the constant's value instead.
        val constant = Regex("""const val (?:NAME|PREFS|PREFS_NAME|FILE)\s*=\s*"([A-Za-z0-9_.]+)"""")
        for (file in sources) {
            val text = file.readText()
            literal.findAll(text).forEach { found += it.groupValues[1] }
            if (text.contains("SecurePrefs.open") || text.contains("getSharedPreferences")) {
                constant.findAll(text).forEach { found += it.groupValues[1] }
            }
        }
        assertTrue("the scanner found no preference stores at all — it has stopped working", found.size > 5)

        val classified = portable + private.keys
        assertEquals(
            "a preference store exists in the source that the backup policy has never been told " +
                "about. Add it to `portable` or `private` in this test AND, if portable, to both " +
                "xml rule files. Defaulting it to either is what produced this bug the first time.",
            emptySet<String>(), found - classified
        )
    }
}

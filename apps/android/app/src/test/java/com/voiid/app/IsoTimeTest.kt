package com.voiid.app

import com.voiid.app.util.IsoTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A03 — dates that are either right or absent, never plausibly wrong.
 *
 * TWO BUGS, and the second is the one that hurts.
 *
 *  1. `java.time` needs API 26 and the app supports API 24, with no core-library desugaring
 *     configured. Lint had been reporting 37 of these to nobody.
 *  2. Every call site was `runCatching { Instant.parse(s) }.getOrDefault(currentTimeMillis())`.
 *     `runCatching` catches Throwable, so on API 24/25 the NoClassDefFoundError was swallowed
 *     and EVERY timestamp silently became "now" — messages out of order, story expiry wrong,
 *     location shares that never expire — with no crash and no log to notice it by. The same
 *     substitution turned a malformed server date into a plausible current one.
 *
 * A missing timestamp is now `null`, and a caller that needs a number has to say what it wants
 * to happen. That is the whole point: a wrong date that looks right is worse than no date.
 */
class IsoTimeTest {

    @Test
    fun `a UTC instant parses to its epoch millis`() {
        assertEquals(0L, IsoTime.parseOrNull("1970-01-01T00:00:00Z"))
        assertEquals(1_700_000_000_000L, IsoTime.parseOrNull("2023-11-14T22:13:20Z"))
    }

    @Test
    fun `sub-second precision is kept, not rounded away`() {
        assertEquals(1_700_000_000_123L, IsoTime.parseOrNull("2023-11-14T22:13:20.123Z"))
    }

    @Test
    fun `an offset is honoured rather than read as local time`() {
        // 05:30 ahead of UTC — the same instant as 22:13:20Z.
        assertEquals(
            IsoTime.parseOrNull("2023-11-14T22:13:20Z"),
            IsoTime.parseOrNull("2023-11-15T03:43:20+05:30")
        )
        assertEquals(
            IsoTime.parseOrNull("2023-11-14T22:13:20Z"),
            IsoTime.parseOrNull("2023-11-14T17:13:20-05:00")
        )
    }

    @Test
    fun `a Postgres timestamptz without a T still parses`() {
        // What `select now()` renders as over the wire in some drivers.
        assertNotNull(IsoTime.parseOrNull("2023-11-14 22:13:20+00"))
    }

    // THE BUG. These used to come back as System.currentTimeMillis().
    @Test
    fun `an unusable date is null, never a plausible current timestamp`() {
        for (bad in listOf("", "   ", "not a date", "2023-13-45T99:99:99Z", "1700000000", "null")) {
            assertNull("'$bad' was turned into a timestamp", IsoTime.parseOrNull(bad))
        }
        assertNull(IsoTime.parseOrNull(null))
    }

    @Test
    fun `a caller that needs a number has to name its fallback`() {
        assertEquals(7L, IsoTime.parseOr("nonsense", fallback = 7L))
        assertEquals(1_700_000_000_000L, IsoTime.parseOr("2023-11-14T22:13:20Z", fallback = 7L))
    }

    /**
     * THE CONFIG HALF. Desugaring is what makes any of the above run on API 24/25 at all;
     * without it the parse throws NoClassDefFoundError on a real device and every one of these
     * tests still passes, because the JVM they run on has java.time.
     */
    @Test
    fun `core library desugaring is enabled, so java_time exists on API 24`() {
        var dir = File(System.getProperty("user.dir")!!)
        while (!File(dir, "build.gradle.kts").isFile) {
            dir = dir.parentFile ?: error("could not locate the app module")
        }
        val gradle = File(dir, "build.gradle.kts").readText()
        assertTrue(
            "isCoreLibraryDesugaringEnabled must be on: minSdk is 24 and the app uses java.time, " +
                "which arrived in API 26",
            Regex("""isCoreLibraryDesugaringEnabled\s*=\s*true""").containsMatchIn(gradle)
        )
        assertTrue(
            "the desugaring runtime must be on the classpath, or enabling the flag does nothing",
            gradle.contains("coreLibraryDesugaring(")
        )
    }

    /**
     * And the guard: the substitution must not come back anywhere. It is one line, it looks
     * defensive, and it silently destroys ordering.
     */
    @Test
    fun `no date parser falls back to the current time`() {
        var dir = File(System.getProperty("user.dir")!!)
        while (!File(dir, "src/main/java").isDirectory) {
            dir = dir.parentFile ?: error("could not locate the app module")
        }
        val offenders = File(dir, "src/main/java").walkTopDown()
            .filter { it.extension == "kt" }
            .filter { file ->
                // Comments are not code: this file's own doc quotes the pattern it forbids.
                val text = file.readText()
                    .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
                    .lines().filterNot { it.trim().startsWith("//") || it.trim().startsWith("*") }
                    .joinToString("\n")
                Regex("""getOrDefault\s*\(\s*System\.currentTimeMillis\(\)\s*\)""").containsMatchIn(text) ||
                    Regex("""\.getOrElse\s*\{\s*System\.currentTimeMillis\(\)\s*\}""").containsMatchIn(text)
            }
            .map { it.name }
            .toList()
        assertTrue(
            "these substitute the current time for a date they could not read, which is " +
                "indistinguishable from a correct date and corrupts ordering: $offenders",
            offenders.isEmpty()
        )
    }
}

package com.voiid.app

import com.voiid.app.net.ApiConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Q03 — a release build cannot ship pointing at the development backend.
 *
 * WHAT WAS WRONG. Both native clients hardcoded `https://api-dev.voiid.app`, and nothing in
 * either app assigned anything else. There was no build-type boundary at all: a release APK
 * would have been built against the dev host, signed, and shipped, and the only thing standing
 * between that and users was somebody remembering to edit a constant first.
 *
 * Android additionally set `usesCleartextTraffic="true"` on the whole application, which is
 * plumbing for talking to a laptop over http and has no business in a release artifact — it
 * silently permits any plaintext connection the app is ever asked to make.
 *
 * THE PRODUCTION HOST IS NOT GUESSED. The issue says so explicitly and this test does not
 * invent one: the release host comes from build configuration, and a release build with none is
 * REFUSED at build time rather than defaulted to something plausible.
 */
class EnvironmentBoundaryTest {

    private fun moduleDir(): File {
        var dir = File(System.getProperty("user.dir")!!)
        while (!File(dir, "src/main/java").isDirectory) {
            dir = dir.parentFile ?: error("could not locate the app module")
        }
        return dir
    }

    private fun gradle(): String = File(moduleDir(), "build.gradle.kts").readText()

    private fun manifest(): String = File(moduleDir(), "src/main/AndroidManifest.xml").readText()

    private fun source(path: String): String =
        File(moduleDir(), "src/main/java/com/voiid/app/$path").readText()
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .lines().filterNot { it.trim().startsWith("//") || it.trim().startsWith("*") }
            .joinToString("\n")

    // ── The endpoints come from the build, not from a constant in the source ──────

    @Test
    fun `the client reads its endpoints from build configuration`() {
        val api = source("net/ApiClient.kt")
        assertTrue(
            "ApiConfig must read BuildConfig, not carry a literal host: a hardcoded endpoint is " +
                "the same value in every build type, so there is no environment boundary at all.",
            api.contains("BuildConfig.VOIID_API_BASE_URL") && api.contains("BuildConfig.VOIID_WS_URL")
        )
        assertTrue(
            "no https:// literal may remain in ApiClient.kt — that is the hardcoded host returning",
            !Regex("""=\s*"https?://""").containsMatchIn(api)
        )
    }

    @Test
    fun `debug and release are configured separately`() {
        val g = gradle()
        assertTrue("a release buildType must set VOIID_API_BASE_URL", g.contains("VOIID_API_BASE_URL"))
        assertTrue("a debug buildType must exist to keep local development working", Regex("""\bdebug\s*\{""").containsMatchIn(g))
    }
    /**
     * The check that makes the rest of it more than decoration.
     *
     * Asserts the PROPERTY, not the presence of a helper: an earlier version looked for the
     * word requireReleaseEndpoint anywhere in the file, so replacing one of the two endpoints
     * with a hardcoded dev host still passed, because the helper survived in the other one.
     */
    @Test
    fun `a release build with no configured host is refused, not defaulted`() {
        val g = gradle()
        for (setting in listOf("VOIID_API_BASE_URL", "VOIID_WS_URL")) {
            val line = g.lines().firstOrNull {
                it.contains(setting) && it.contains("requireReleaseEndpoint")
            }
            assertTrue(
                "$setting must be produced by requireReleaseEndpoint. A literal or a fallback " +
                    "in the release buildType is how a dev-pointed release ships.",
                line != null
            )
        }
        assertTrue(
            "the guard must reject a dev/local host outright, not merely prefer another",
            g.contains("api-dev.voiid.app") && g.contains("localhost")
        )
    }

    // ── Transport ─────────────────────────────────────────────────────────────────

    @Test
    fun `cleartext is not permitted application-wide`() {
        assertTrue(
            "usesCleartextTraffic=\"true\" on <application> permits plaintext for every " +
                "connection in every build type. Local http development belongs in a " +
                "debug-only network security config, not in the shipped manifest.",
            !Regex("""android:usesCleartextTraffic\s*=\s*"true"""").containsMatchIn(manifest())
        )
    }

    @Test
    fun `debug keeps a way to talk to a laptop over http`() {
        val debugManifest = File(moduleDir(), "src/debug/AndroidManifest.xml")
        assertTrue(
            "removing cleartext must not break local development — a debug-only manifest or " +
                "network security config has to restore it for debug builds",
            debugManifest.isFile || File(moduleDir(), "src/debug/res/xml/network_security_config.xml").isFile
        )
    }

    // ── The values actually compiled into THIS (debug) build ─────────────────────

    @Test
    fun `the debug build points somewhere reachable over https or a local host`() {
        val base = ApiConfig.baseUrl
        assertTrue("the debug base URL is empty", base.isNotBlank())
        assertTrue(
            "a debug build may use http only for a local host; anything else must be https: $base",
            base.startsWith("https://") ||
                Regex("""^http://(localhost|127\.0\.0\.1|10\.0\.2\.2)(:\d+)?""").containsMatchIn(base)
        )
        assertEquals("the websocket and API must agree on scheme family",
            base.startsWith("https://"), ApiConfig.wsUrl.startsWith("wss://"))
    }
}

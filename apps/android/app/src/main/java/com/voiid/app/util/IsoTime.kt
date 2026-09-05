package com.voiid.app.util

import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter

/**
 * Parsing the timestamps the server sends (A03).
 *
 * ── WHAT THIS REPLACES, AND WHY IT WAS WORSE THAN A CRASH ────────────────────────
 *
 * Every call site was the same line:
 *
 *     runCatching { Instant.parse(s).toEpochMilli() }.getOrDefault(System.currentTimeMillis())
 *
 * `java.time` arrived in API 26 and this app supports API 24, with no core-library desugaring
 * configured — lint had been reporting 37 of those calls to nobody. On an API 24 or 25 device
 * the call throws NoClassDefFoundError, and `runCatching` catches Throwable, so the error was
 * swallowed and EVERY timestamp became the current time. Messages out of order, story expiry
 * wrong, location shares that never expire — with no crash and nothing in the log to notice it
 * by. The same substitution turned a malformed date from the server into a plausible one.
 *
 * Desugaring (see build.gradle.kts) makes java.time real on API 24. This makes the failure
 * honest: an unusable date is `null`, and a caller that needs a number has to say what it wants
 * instead. A wrong date that looks right is worse than a missing one.
 */
object IsoTime {

    /**
     * Epoch millis, or null if the string is not a timestamp we can read.
     *
     * Accepts the two shapes the backend actually produces: ISO-8601 with `T` and a `Z` or
     * numeric offset, and Postgres's `timestamptz` rendering with a space instead of the `T`.
     * The offset is honoured rather than assumed — reading `+05:30` as local time would shift
     * every timestamp by hours in a way nobody would attribute to parsing.
     */
    fun parseOrNull(value: String?): Long? {
        val text = value?.trim().orEmpty()
        if (text.isEmpty()) return null
        return runCatching { Instant.parse(text).toEpochMilli() }.getOrNull()
            ?: runCatching { OffsetDateTime.parse(text).toInstant().toEpochMilli() }.getOrNull()
            ?: runCatching {
                OffsetDateTime.parse(text.replace(' ', 'T'), DateTimeFormatter.ISO_OFFSET_DATE_TIME)
                    .toInstant().toEpochMilli()
            }.getOrNull()
            ?: runCatching {
                // Postgres renders a whole-hour offset as `+00`, which ISO_OFFSET_DATE_TIME
                // rejects; widening it to `+00:00` is the only difference.
                val widened = text.replace(' ', 'T').replace(Regex("([+-])(\\d{2})$"), "$1$2:00")
                OffsetDateTime.parse(widened, DateTimeFormatter.ISO_OFFSET_DATE_TIME)
                    .toInstant().toEpochMilli()
            }.getOrNull()
    }

    /**
     * Epoch millis, or the fallback the CALLER chose.
     *
     * Deliberately requires the fallback to be named at the call site. The bug this file exists
     * for was a default nobody had to think about, hidden inside the parser.
     */
    fun parseOr(value: String?, fallback: Long): Long = parseOrNull(value) ?: fallback
}

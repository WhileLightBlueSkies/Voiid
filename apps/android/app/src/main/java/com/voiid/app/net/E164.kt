package com.voiid.app.net

/**
 * The ONE strict E.164 normalizer used by every system-facing surface — port of iOS
 * `CallManager.normalizedE164` (CallManager.swift).
 *
 * CONSISTENCY IS THE WHOLE POINT. Both Android surfaces we are feeding — the Telecom
 * handle that ends up in the system call log, and the `Phone.NUMBER` row the contacts
 * aggregator uses to merge our RawContact into the user's real contact — match on the
 * number STRING. "+91 91234 56789" and "+919123456789" are two different people as far
 * as the call log and the aggregator are concerned, so the same peer would accumulate
 * duplicate, separately-linked entries. Every handle for a given peer must therefore be
 * byte-identical, which means normalizing here on write AND at use.
 *
 * DELIBERATELY DIFFERENT FROM [ContactsService.normalizeE164], and they must not be
 * swapped for one another:
 *  - `ContactsService.normalizeE164` is the *discovery* normalizer. It invents a `+91`
 *    country code for national-format numbers because a wrong guess there only costs a
 *    missed hash match — a private, recoverable failure.
 *  - This one returns null rather than guessing. A wrong guess here writes a bad number
 *    into the user's address book and into the system call log, links the call to the
 *    WRONG person, and is not recoverable by re-running anything. A `null` simply means
 *    "no tel: handle for this peer", which degrades to the opaque fallback handle.
 */
object E164 {

    /** Strict E.164, or null. See the class docs for why this never guesses. */
    fun normalize(raw: String?): String? {
        val s = raw?.trim() ?: return null
        if (s.isEmpty()) return null
        // Keep a leading "+" if it was there; otherwise we cannot invent a country code,
        // and a national-format number would link to the wrong contact entirely.
        if (!s.startsWith("+")) return null
        val digits = s.filter { it.isDigit() }
        if (digits.isEmpty()) return null
        val out = "+$digits"
        // E.164 allows at most 15 digits; anything longer is not a phone number.
        if (out.length < 8 || out.length > 16) return null
        return out
    }

    /** True when both raw strings denote the same phone number after normalization. */
    fun sameNumber(a: String?, b: String?): Boolean {
        val na = normalize(a) ?: return false
        val nb = normalize(b) ?: return false
        return na == nb
    }
}

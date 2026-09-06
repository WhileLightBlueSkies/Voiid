package com.voiid.app.net

/**
 * What to do when an encrypted preference store will not open (A02).
 *
 * ── WHY THIS IS A SEPARATE, PURE OBJECT ──────────────────────────────────────────
 *
 * The old handler had one response to every failure — delete the preference file, and if the
 * rebuild also failed, delete the Android Keystore master key. That key is shared by every
 * encrypted store in the app, so the recovery path for ONE unreadable file destroyed the E2E
 * identity, the session token, the message history and the account-backup master secret
 * together, silently, on launch. A transient error was enough to trigger it.
 *
 * The decision is the dangerous part, not the file handling, so it lives here with no Android
 * types in it and is unit-tested directly. Keeping it inline is how it went unexamined.
 *
 * ── THE PRINCIPLE ────────────────────────────────────────────────────────────────
 *
 * Destroying user data is never the automatic answer. A locked device is temporary. An
 * invalidated key is permanent but its consequence belongs to the user. Corruption is the only
 * case that justifies moving a file, and it is moved ASIDE rather than deleted, so an explicit
 * reset stays a decision somebody makes rather than one that already happened.
 */
object SecurePrefsPolicy {

    /** Why the store would not open. These are not interchangeable. */
    enum class Failure {
        /** The device is locked, or Keystore wants user authentication. Temporary. */
        DEVICE_LOCKED,

        /** The Keystore entry is gone or permanently invalidated — a new biometric enrolment,
         *  a lock-screen change, a restore onto different hardware. The ciphertext is real and
         *  is now unreadable forever. */
        KEY_INVALIDATED,

        /** The key is fine and the bytes are not: a truncated write, a bad restore, a
         *  half-flushed file. This is the only failure a file operation can help with. */
        CORRUPTED,

        /** Something not anticipated. The old code's guess here was "delete everything". */
        UNKNOWN,
    }

    enum class Action {
        /** Wait and try again. Costs a moment; costs nothing if wrong. */
        RETRY,

        /** Say so, and stop. The caller decides; a reset is the user's to authorise. */
        REPORT_UNAVAILABLE,
    }

    /**
     * How many opens are attempted before a temporary failure is reported as unavailable.
     *
     * Small on purpose: this runs while something is waiting for a store, and the condition it
     * covers (a locked device during direct boot, Keystore briefly busy) either clears in
     * milliseconds or is not going to clear on this call.
     */
    const val MAX_ATTEMPTS = 3

    /** Milliseconds to wait before attempt N+1. */
    fun backoffMillis(attempt: Int): Long = 50L * attempt

    /**
     * Read the failure out of the exception, following the cause chain — androidx and Tink
     * both wrap liberally, so the interesting exception is rarely the outermost one.
     */
    fun classify(error: Throwable): Failure {
        var cursor: Throwable? = error
        val seen = HashSet<Throwable>()
        while (cursor != null && seen.add(cursor)) {
            val name = cursor.javaClass.simpleName
            val message = cursor.message.orEmpty().lowercase()

            // Order matters: "permanently invalidated" also mentions the key, and a locked
            // device also throws KeyStoreException. The most specific reading wins.
            if (name == "KeyPermanentlyInvalidatedException" ||
                message.contains("permanently invalidated") ||
                message.contains("key not found") ||
                message.contains("keystore entry") && message.contains("not found")
            ) return Failure.KEY_INVALIDATED

            if (name == "UserNotAuthenticatedException" ||
                message.contains("user not authenticated") ||
                message.contains("device is locked") ||
                message.contains("keystore is not unlocked") ||
                message.contains("locked or not initialized")
            ) return Failure.DEVICE_LOCKED

            if (name == "AEADBadTagException" ||
                name == "InvalidProtocolBufferException" ||
                message.contains("tag mismatch") ||
                message.contains("decryption failed") ||
                message.contains("invalid keyset") ||
                message.contains("invalid protocol") ||
                message.contains("no keyset found")
            ) return Failure.CORRUPTED

            cursor = cursor.cause
        }
        return Failure.UNKNOWN
    }

    /**
     * The table. Note that no row is destructive: the most it will do is move one file aside.
     *
     * `attempt` is 1-based and counts opens already made.
     */
    fun decide(failure: Failure, attempt: Int): Action = when (failure) {
        // Temporary by definition. Retry while it is worth retrying, then say so — the one
        // thing that must never happen is discarding data because a phone was locked.
        Failure.DEVICE_LOCKED -> if (attempt < MAX_ATTEMPTS) Action.RETRY else Action.REPORT_UNAVAILABLE

        // The data is genuinely unreadable, and it is still the user's data. Regenerating an
        // identity on their behalf is what made "my messages disappeared" a support case.
        Failure.KEY_INVALIDATED -> Action.REPORT_UNAVAILABLE

        // The one case a file operation answers, and it is answered by moving the file, not
        // by removing it: the ciphertext might matter later, and the evidence certainly does.
        Failure.CORRUPTED -> Action.REPORT_UNAVAILABLE

        // Never guess. Guessing is the bug.
        Failure.UNKNOWN -> Action.REPORT_UNAVAILABLE
    }

    /**
     * The name a quarantined store's file takes.
     *
     * Keeps the store name legible so an operator can tell what was set aside, and stamps the
     * time so a second quarantine cannot overwrite the first — the evidence of a repeated
     * failure is the most useful thing about it.
     */
    fun quarantineName(store: String, at: Long): String = "$store.quarantined-$at.xml"
}

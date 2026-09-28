package com.voiid.app.net

import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The V PIN proof: what this phone sends the server INSTEAD of the PIN. Port of iOS
 * `VPinProof.swift`; the recipe's source of truth is backend/api/src/vpin.ts.
 *
 * The server checks the proof and counts every wrong one — 5 wrong, and the PIN locks for
 * 24 hours. The PIN itself never leaves the phone:
 *
 *     proof = PBKDF2-HMAC-SHA256(password = pin (UTF-8),
 *                                salt     = "voiid.vpin.auth.v1:" + authSalt (16 bytes),
 *                                rounds   = 600,000,
 *                                length   = 32 bytes)
 *
 * ── WHY PBKDF2 IS WRITTEN OUT HERE ────────────────────────────────────────────────────
 * Android's `SecretKeyFactory("PBKDF2WithHmacSHA256")` is backed by a pure-Java provider on
 * many devices, several times slower at 600k rounds than iOS — seconds of a frozen button.
 * `Mac("HmacSHA256")` is native (Conscrypt), so the loop below runs close to iOS speed. With
 * a 32-byte output PBKDF2 is a single block (RFC 8018 §5.2), so the whole algorithm is the
 * few lines in [pbkdf2Sha256]. `VPinProofTest` pins it to the shared known answer.
 *
 * ── THIS MUST MATCH iOS AND THE SERVER, BYTE FOR BYTE ─────────────────────────────────
 * A PIN set on one phone is unlocked from the next. A single byte of drift and that restore
 * fails as "wrong PIN" with no other symptom.
 */
object VPinProof {
    const val SALT_PREFIX = "voiid.vpin.auth.v1:"
    const val ROUNDS = 600_000
    const val LENGTH = 32
    const val AUTH_SALT_LENGTH = 16

    /** A fresh random salt for a new V PIN. */
    fun newAuthSalt(): ByteArray = ByteArray(AUTH_SALT_LENGTH).also { SecureRandom().nextBytes(it) }

    /** The proof for [pin] over [authSalt]. Slow on purpose — call it off the main thread. */
    fun proof(pin: String, authSalt: ByteArray): ByteArray =
        pbkdf2Sha256(pin.toByteArray(Charsets.UTF_8), SALT_PREFIX.toByteArray(Charsets.UTF_8) + authSalt, ROUNDS)

    /** PBKDF2-HMAC-SHA256 for exactly one 32-byte block: T1 = U1 ⊕ U2 ⊕ … ⊕ Uc. */
    internal fun pbkdf2Sha256(password: ByteArray, salt: ByteArray, rounds: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(password, "HmacSHA256")) }
        // U1 = HMAC(P, S || INT(1)), the block index as a 4-byte big-endian integer.
        var u = mac.doFinal(salt + byteArrayOf(0, 0, 0, 1))
        val t = u.copyOf()
        for (i in 1 until rounds) {
            u = mac.doFinal(u)
            for (j in t.indices) t[j] = (t[j].toInt() xor u[j].toInt()).toByte()
        }
        return t
    }
}

/**
 * Which V PINs may be chosen. Port of iOS `PinRules`, list included, so both apps accept and
 * refuse exactly the same PINs — a PIN one app allows and the other rejects is a support call.
 *
 * Exactly 8 digits, and not one of the PINs anyone guessing would try first. With only 5
 * guesses a day, the common-PIN list is most of what an attacker's day would be spent on.
 */
object VPinRules {
    const val LENGTH = 8

    private val commonPins = setOf(
        // Runs and reverses.
        "12345678", "87654321", "01234567", "76543210", "23456789", "98765432",
        // Single repeated digit.
        "00000000", "11111111", "22222222", "33333333", "44444444",
        "55555555", "66666666", "77777777", "88888888", "99999999",
        // Two- and four-digit patterns tiled to length.
        "12121212", "21212121", "10101010", "13131313", "69696969",
        "11223344", "12341234", "43214321", "11112222", "12312312",
        // Dates people actually use.
        "19801980", "19901990", "20002000", "20202020", "01011990",
        "01012000", "01011980", "31121999",
        // Keypad shapes.
        "14725836", "15935748", "11235813",
    )

    /** Why [pin] can't be chosen, or null if it can. Same wording as iOS. */
    fun rejectionReason(pin: String): String? = when {
        !pin.all { it in '0'..'9' } -> "Digits only."
        pin.length != LENGTH -> "Your PIN must be exactly $LENGTH digits."
        pin in commonPins -> "That PIN is too easy to guess."
        else -> null
    }
}

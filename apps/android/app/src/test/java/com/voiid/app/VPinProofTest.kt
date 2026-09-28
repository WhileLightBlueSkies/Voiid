package com.voiid.app

import com.voiid.app.net.VPinProof
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import java.util.Base64
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * The V PIN proof must match the server and iOS byte for byte — a PIN set on an iPhone is
 * unlocked from an Android phone and vice versa, and any drift fails as "wrong PIN" with
 * nothing else to go on. Same vector as backend test/vpin.test.ts and iOS VPinProof.swift.
 */
class VPinProofTest {
    private val salt = ByteArray(16) { it.toByte() }   // 00 01 … 0f

    @Test fun knownAnswerMatchesServerAndIos() {
        assertEquals(
            "+UVIgV0f50UAMTdE4+wxE22X62xIZX1Gxyos9o1wzyA=",
            Base64.getEncoder().encodeToString(VPinProof.proof("24681357", salt)),
        )
    }

    /** The hand-written PBKDF2 agrees with the JDK's own, at a cheap round count. */
    @Test fun handWrittenPbkdf2AgreesWithTheJdk() {
        val password = "13572468"
        val fullSalt = VPinProof.SALT_PREFIX.toByteArray() + salt
        val jdk = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
            .generateSecret(PBEKeySpec(password.toCharArray(), fullSalt, 1000, 256)).encoded
        val ours = VPinProof.pbkdf2Sha256(password.toByteArray(), fullSalt, 1000)
        assertEquals(Base64.getEncoder().encodeToString(jdk), Base64.getEncoder().encodeToString(ours))
    }

    @Test fun differentPinsGiveDifferentProofs() {
        assertNotEquals(
            Base64.getEncoder().encodeToString(VPinProof.proof("24681357", salt)),
            Base64.getEncoder().encodeToString(VPinProof.proof("24681358", salt)),
        )
    }

    @Test fun proofIs32BytesAndSaltIs16() {
        assertEquals(32, VPinProof.proof("24681357", salt).size)
        assertEquals(16, VPinProof.newAuthSalt().size)
    }
}

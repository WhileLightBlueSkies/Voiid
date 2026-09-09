package com.voiid.app
import com.voiid.app.net.CallKeyProtocol
import org.junit.Assert.*
import org.junit.Test

class CallKeyProtocolTest {
    @Test fun matchesIosV1CommitmentAndIsSymmetric() {
        val key = ByteArray(16) { it.toByte() }
        val salt = ByteArray(14) { (it + 16).toByte() }
        val a = CallKeyProtocol.fingerprint("v=0\r\na=fingerprint:SHA-256 aa:bb\r\n")!!
        val b = CallKeyProtocol.fingerprint("a=fingerprint:sha-256 cc:dd\n")!!
        assertEquals("sha-256 AA:BB", a)
        val tag = CallKeyProtocol.commitment(key, salt, a, b)
        assertEquals("a21ba04a2cb9e210d34e5286eef4095487c47492d14b5fe2d1ce56d98d1f110f", tag.joinToString("") { "%02x".format(it) })
        assertArrayEquals(tag, CallKeyProtocol.commitment(key, salt, b, a))
        assertFalse(tag.contentEquals(CallKeyProtocol.commitment(key, salt, a, "sha-256 EE:FF")))
        assertFalse(tag.contentEquals(CallKeyProtocol.commitment(ByteArray(16) { 9 }, salt, a, b)))
    }
    @Test fun missingFingerprintNeverVerifies() {
        assertNull(CallKeyProtocol.fingerprint(null))
        assertNull(CallKeyProtocol.fingerprint("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"))
        assertNull(CallKeyProtocol.fingerprint("a=fingerprint:sha-256"))
    }
}

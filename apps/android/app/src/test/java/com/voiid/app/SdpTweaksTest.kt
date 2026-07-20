package com.voiid.app

import com.voiid.app.net.SdpTweaks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Opus munging runs on every offer and answer of every call, so its failure mode matters:
 * it must improve the SDP when it recognises it and return the input byte-for-byte when it
 * doesn't. These pin both halves of that contract.
 */
class SdpTweaksTest {

    private fun sdp(vararg lines: String) = lines.joinToString("\r\n")

    @Test
    fun `rewrites an existing opus fmtp line`() {
        val input = sdp(
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10;useinbandfec=0",
        )
        val out = SdpTweaks.enableOpusFecDtx(input)
        val fmtp = out.split("\r\n").first { it.startsWith("a=fmtp:111") }
        assertTrue("keeps unrelated params", fmtp.contains("minptime=10"))
        assertTrue(fmtp.contains("useinbandfec=1"))
        assertTrue(fmtp.contains("usedtx=1"))
        // The pre-existing useinbandfec=0 must be replaced, not merely appended after.
        assertTrue("stale value removed", !fmtp.contains("useinbandfec=0"))
    }

    @Test
    fun `adds an fmtp line when none exists`() {
        val input = sdp(
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2",
            "a=rtcp-fb:111 transport-cc",
        )
        val out = SdpTweaks.enableOpusFecDtx(input).split("\r\n")
        assertEquals("a=fmtp:111 useinbandfec=1;usedtx=1", out[2])
        assertTrue("existing lines preserved", out.contains("a=rtcp-fb:111 transport-cc"))
    }

    @Test
    fun `leaves sdp untouched when opus is absent`() {
        val input = sdp(
            "m=audio 9 UDP/TLS/RTP/SAVPF 8",
            "a=rtpmap:8 PCMA/8000",
        )
        assertEquals(input, SdpTweaks.enableOpusFecDtx(input))
    }

    @Test
    fun `handles bare newline sdp and multiple opus payload types`() {
        val input = "m=audio 9 UDP/TLS/RTP/SAVPF 111 112\na=rtpmap:111 opus/48000/2\na=rtpmap:112 opus/48000/2"
        val out = SdpTweaks.enableOpusFecDtx(input)
        assertTrue("no CRLF introduced", !out.contains("\r\n"))
        assertTrue(out.contains("a=fmtp:111 useinbandfec=1;usedtx=1"))
        assertTrue(out.contains("a=fmtp:112 useinbandfec=1;usedtx=1"))
    }
}

package com.voiid.app.net

/**
 * Small, surgical SDP rewrites applied between `createOffer`/`createAnswer` and
 * `setLocalDescription`.
 *
 * We deliberately do NOT touch bandwidth (`b=AS:`), the codec preference order, or anything
 * that would disable WebRTC's own congestion control / adaptive bitrate — those adapt far
 * better to a bad network than any static tuning we could hard-code.
 */
object SdpTweaks {

    /**
     * Turn on Opus in-band FEC and DTX.
     *
     * * `useinbandfec=1` — the encoder piggybacks a low-bitrate copy of the previous frame on
     *   the next packet, so a single lost packet is reconstructed instead of concealed. This is
     *   the single highest-value knob for lossy cellular links.
     * * `usedtx=1` — stop sending during silence, which cuts bytes (and therefore loss
     *   opportunities and battery) on half-duplex conversations.
     *
     * Rewrites the existing `a=fmtp:<pt>` line for the Opus payload type, or synthesises one
     * directly after the `a=rtpmap` line if the offer had none. If no Opus payload type is
     * present (voice-only codecs disabled, odd build, munged remote), the SDP is returned
     * completely untouched — never fail a call over a codec hint.
     */
    fun enableOpusFecDtx(sdp: String): String = runCatching {
        val eol = if (sdp.contains("\r\n")) "\r\n" else "\n"
        val lines = sdp.split(eol).toMutableList()

        // Opus can be negotiated on more than one payload type; fix up every one of them.
        val opusPts = lines.mapNotNull { line ->
            RTPMAP_OPUS.find(line)?.groupValues?.getOrNull(1)
        }
        if (opusPts.isEmpty()) return sdp

        for (pt in opusPts) {
            val fmtpIdx = lines.indexOfFirst { it.startsWith("a=fmtp:$pt ") }
            if (fmtpIdx >= 0) {
                lines[fmtpIdx] = withParams(lines[fmtpIdx])
            } else {
                val rtpmapIdx = lines.indexOfFirst { it.startsWith("a=rtpmap:$pt ") }
                if (rtpmapIdx >= 0) {
                    lines.add(rtpmapIdx + 1, "a=fmtp:$pt useinbandfec=1;usedtx=1")
                }
            }
        }
        lines.joinToString(eol)
    }.getOrDefault(sdp)

    /** Append the two params to an `a=fmtp:` line, replacing any pre-existing values. */
    private fun withParams(fmtpLine: String): String {
        val head = fmtpLine.substringBefore(' ')
        val params = fmtpLine.substringAfter(' ', "")
            .split(';')
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("useinbandfec=") && !it.startsWith("usedtx=") }
        val merged = (params + "useinbandfec=1" + "usedtx=1").joinToString(";")
        return "$head $merged"
    }

    private val RTPMAP_OPUS = Regex("""^a=rtpmap:(\d+)\s+opus/48000""", RegexOption.IGNORE_CASE)
}

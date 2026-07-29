package com.voiid.app.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/**
 * The three video renditions a clip is published in, and how one gets chosen.
 * Port of iOS `ClipQuality.swift` — keep the ladder identical on both platforms.
 *
 * WHY THREE AND NOT ADAPTIVE STREAMING: true ABR (HLS/DASH) needs the source segmented
 * into chunks plus a manifest, which in practice means handing transcoding to a service.
 * Three fixed renditions produced ON-DEVICE need no new backend at all — the phone
 * already has the encoder, and the app already has presign+PUT. The trade is that quality
 * is chosen ONCE per playback rather than switching mid-stream.
 */
enum class ClipQuality(val wire: String, val longEdge: Int, val bitrate: Int, val label: String) {
    SD("sd", 854, 1_200_000, "480p"),
    HD("hd", 1280, 2_800_000, "720p"),

    /**
     * Bitrates are chosen so a 90s clip stays well inside the 100 MB cap: 90s at
     * 4.5 Mbps ≈ 50 MB, leaving headroom for audio and container overhead.
     */
    FHD("fhd", 1920, 4_500_000, "1080p");

    companion object {
        /**
         * The rendition to request for fullscreen playback right now.
         *
         * Deliberately coarse. Android exposes "is this metered" and the transport type;
         * there is no reliable bandwidth estimate before bytes move, and guessing one
         * would be worse than honest coarse buckets.
         *
         * A METERED connection is treated as a hard floor: the user pays per byte, and
         * quietly streaming 1080p over it is a bug they cannot see but are billed for.
         */
        fun preferred(context: Context): ClipQuality {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return HD
            val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return HD

            val unmetered = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            if (!unmetered) return SD

            val wifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
            return if (wifi) FHD else HD
        }
    }
}

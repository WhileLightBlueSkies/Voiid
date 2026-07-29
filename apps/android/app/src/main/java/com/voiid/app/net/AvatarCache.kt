package com.voiid.app.net

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.voiid.app.main.MediaCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap

/**
 * One shared resolver for profile/avatar images — port of iOS `AvatarCache.swift`.
 *
 * WHY: a `photo_url` is fetched ONCE and then renders instantly everywhere a face appears
 * (chat grid, chat header, map markers, contact rows). Before this, every avatar call site
 * re-ran its own two-request presigned download on each appearance, which is why peer photos
 * never cached and the chat home grid re-hit the network on every scroll.
 *
 * A `photo_url` may be an ABSOLUTE URL (older/profile CDN) or an opaque R2 OBJECT KEY
 * (uploaded via [MediaService], needs a presigned GET). This resolves both, so callers never
 * have to branch on which kind of ref they hold.
 *
 * STORAGE: the bytes/bitmaps themselves live in [MediaCache] (memory + the app's private
 * `media/` dir, keyed by SHA-256 of the ref) — the same tiers chat media already uses, so
 * sign-out wipes avatars along with everything else and there is no second cache to purge.
 * This object only adds the *resolution* rules and single-flight de-duplication.
 *
 * SINGLE-FLIGHT: [inFlight] means N composables asking for the same face concurrently (a grid
 * of 12 tiles, the map with 8 markers) produce exactly ONE presign + download, not N. A ref
 * that fails is remembered in [failed] so a photo-less or broken peer doesn't re-hit the
 * network on every recomposition — that is the "no per-frame network requests" guarantee.
 */
object AvatarCache {

    /** Refs whose fetch already failed once — never retried for the life of the process. */
    private val failed = ConcurrentHashMap.newKeySet<String>()

    /** ref -> lock, so concurrent callers for the same face collapse into one download. */
    private val inFlight = ConcurrentHashMap<String, Mutex>()

    /**
     * Synchronous cache hit (memory only) — safe to call in a composition for an instant first
     * paint. Never touches disk or the network: a miss here just means [resolve] must run.
     */
    fun cached(ref: String?): ImageBitmap? {
        if (ref.isNullOrBlank()) return null
        return MediaCache.image(ref)
    }

    /**
     * Resolve a photo reference to a bitmap, caching the result (memory + disk).
     *
     * Local-first: memory → disk → only then network, so a face seen once renders offline and
     * with no presign round-trip. Suspends; call from a `LaunchedEffect`, never from a
     * composition body. Returns null for a blank ref, a ref that previously failed, or a
     * fetch that fails now.
     */
    suspend fun resolve(context: Context, ref: String?): ImageBitmap? {
        if (ref.isNullOrBlank() || ref in failed) return null
        MediaCache.image(ref)?.let { return it }

        val lock = inFlight.getOrPut(ref) { Mutex() }
        return lock.withLock {
            // A concurrent caller may have completed the fetch while we waited for the lock.
            MediaCache.image(ref)?.let { return@withLock it }
            if (ref in failed) return@withLock null

            withContext(Dispatchers.IO) { MediaCache.image(context, ref) }?.let { return@withLock it }

            val bytes = withContext(Dispatchers.IO) {
                val media = MediaService(TokenStore.get(context))
                runCatching {
                    if (ref.startsWith("http")) media.fetchAbsolute(ref) else media.download(ref)
                }.getOrNull()
            }
            if (bytes == null) { failed.add(ref); return@withLock null }

            val bmp = withContext(Dispatchers.IO) {
                runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }.getOrNull()
            }
            if (bmp == null) { failed.add(ref); return@withLock null }

            MediaCache.putData(context, ref, bytes)          // persist plaintext bytes
            val image = bmp.asImageBitmap()
            MediaCache.putImage(ref, image)
            image
        }.also { inFlight.remove(ref) }
    }

    /**
     * Cache an avatar we ALREADY hold the bytes for (e.g. one just uploaded), so it renders
     * instantly and offline with no download — mirrors iOS `AvatarCache.store`.
     */
    fun store(context: Context, ref: String, bytes: ByteArray) {
        if (ref.isBlank()) return
        failed.remove(ref)
        MediaCache.putData(context, ref, bytes)
        runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }.getOrNull()
            ?.let { MediaCache.putImage(ref, it.asImageBitmap()) }
    }

    /**
     * Sign-out teardown: forget the failure/in-flight bookkeeping. The bytes themselves are
     * dropped by [MediaCache.clear], which [com.voiid.app.net.SessionTeardown] already calls —
     * the next account must not see the previous one's faces.
     */
    fun wipe() {
        failed.clear()
        inFlight.clear()
    }
}

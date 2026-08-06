package com.voiid.app.main.stories

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** Relative "3h" / "12m" / "now" label for a story timestamp (epoch millis). */
fun relativeTime(ms: Long): String {
    val diff = (System.currentTimeMillis() - ms).coerceAtLeast(0)
    val mins = diff / 60_000
    val hours = mins / 60
    return when {
        mins < 1 -> "now"
        hours < 1 -> "${mins}m"
        hours < 24 -> "${hours}h"
        else -> "${hours / 24}d"
    }
}

/**
 * In-memory decoded-frame cache, bounded to an eighth of the heap. A 12MP still is ~48MB as
 * ARGB_8888, so an unbounded map of them holds half a gigabyte across ten stories.
 *
 * The key carries the target size as well as the path: the same file is decoded small for a tray
 * cell and large for the full-screen viewer, and a path-only key would hand the tray's downsampled
 * bitmap back to the viewer, where it reads as blurry.
 */
private val thumbCache = object : LruCache<String, ImageBitmap>(
    (Runtime.getRuntime().maxMemory() / 8).coerceIn(8L shl 20, Int.MAX_VALUE.toLong()).toInt(),
) {
    override fun sizeOf(key: String, value: ImageBitmap): Int = value.width * value.height * 4
}

/** Drops every cached frame. Called when the viewer closes — this heap is not worth holding idle. */
fun clearStoryFrameCache() {
    thumbCache.evictAll()
}

/**
 * Largest power-of-two subsample that still leaves one edge covering the target box. Fit-scaling
 * bounds the drawn size by whichever edge saturates first, so an OR (not AND) is the condition
 * that stops one step before the image would visibly soften.
 */
private fun sampleSizeFor(width: Int, height: Int, targetW: Int, targetH: Int): Int {
    if (targetW <= 0 || targetH <= 0) return 1
    var sample = 1
    while (width / (sample * 2) >= targetW || height / (sample * 2) >= targetH) sample *= 2
    return sample
}

/** Two-pass decode: bounds only, then the real decode at the subsample the display can use. */
private fun decodeSampled(path: String, targetW: Int, targetH: Int): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    val opts = BitmapFactory.Options().apply {
        inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, targetW, targetH)
    }
    return BitmapFactory.decodeFile(path, opts)
}

private fun videoFrame(path: String, targetW: Int, targetH: Int): Bitmap? =
    MediaMetadataRetriever().use { r ->
        r.setDataSource(path)
        // getScaledFrameAtTime decodes straight to the target box (aspect preserved); below 27 the
        // only option is the full-resolution frame.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            r.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, targetW, targetH)
        } else {
            r.getFrameAtTime(0)
        }
    }

/**
 * Longest edge of the blurred backdrop copy. Tiny on purpose: it is blurred and darkened past any
 * point where detail survives, and the upscale to full screen is itself most of the blur — which
 * matters because `Modifier.blur` is a no-op below API 31 and this app ships to API 24.
 */
private const val BACKDROP_PX = 96

private fun frameKey(path: String, targetW: Int, targetH: Int) = "$path@${targetW}x$targetH"

/** Cache hit, or a decode off the main thread that populates it. Null on a missing/unreadable file. */
private suspend fun loadFrame(
    path: String,
    isVideo: Boolean,
    targetW: Int,
    targetH: Int,
): ImageBitmap? {
    val key = frameKey(path, targetW, targetH)
    thumbCache.get(key)?.let { return it }
    if (!File(path).exists()) return null
    val decoded = withContext(Dispatchers.IO) {
        runCatching {
            if (isVideo) videoFrame(path, targetW, targetH) else decodeSampled(path, targetW, targetH)
        }.getOrNull()
    } ?: return null
    return decoded.asImageBitmap().also { thumbCache.put(key, it) }
}

/**
 * A decrypted still frame for a local story file (image bytes decoded directly; a video's first
 * frame pulled via MediaMetadataRetriever), downsampled to [targetWidthPx] x [targetHeightPx].
 * Used for tray cells and viewer prefetch. Returns null while loading / on failure so the caller
 * can show a placeholder.
 */
@Composable
fun rememberStoryThumbnail(
    localPath: String?,
    isVideo: Boolean,
    targetWidthPx: Int,
    targetHeightPx: Int,
): ImageBitmap? {
    val key = localPath?.let { frameKey(it, targetWidthPx, targetHeightPx) }
    var bmp by remember(key) { mutableStateOf(key?.let { thumbCache.get(it) }) }
    LaunchedEffect(key) {
        val p = localPath ?: return@LaunchedEffect
        if (bmp != null) return@LaunchedEffect
        bmp = loadFrame(p, isVideo, targetWidthPx, targetHeightPx)
    }
    return bmp
}

/**
 * Warm a prefetched story's frames into the cache from outside a composition, so the page that
 * opens next pays only the draw. Downloading the bytes is the cheap half of a story appearing;
 * the decode is what the user was watching a spinner for.
 *
 * [fullSize] is reserved for the story immediately next — a screen-sized still is tens of
 * megabytes decoded, and three of those would evict the one on screen to warm stories the viewer
 * may never reach. Everything further out gets only its backdrop copy, which is enough for the
 * page to open on the blurred fill rather than on black while its own decode runs.
 */
suspend fun warmStoryFrame(
    localPath: String,
    isVideo: Boolean,
    targetWidthPx: Int,
    targetHeightPx: Int,
    fullSize: Boolean,
) {
    if (fullSize) loadFrame(localPath, isVideo, targetWidthPx, targetHeightPx)
    loadFrame(localPath, isVideo, BACKDROP_PX, BACKDROP_PX)
}

/**
 * The story is drawn at its true aspect ratio, so anything that is not the screen's shape — a 4:3
 * photo on a 19.5:9 phone is the common case — leaves bands. Filling them with pure black is what
 * the "too much black space" report was about. Both Signal clients and WhatsApp Status put the SAME
 * frame behind, cropped to fill and blurred, so the bands read as an extension of the photo rather
 * than as dead screen.
 *
 * The source is a [BACKDROP_PX] copy on its own cache key, not a second full-resolution decode —
 * trading black bars for memory pressure would just move the bug. The media on top is untouched:
 * this adds a layer, it does not crop the story.
 */
@Composable
private fun StoryBackdrop(localPath: String, isVideo: Boolean) {
    val bmp = rememberStoryThumbnail(localPath, isVideo, BACKDROP_PX, BACKDROP_PX)
    if (bmp != null) {
        Image(
            bmp, null,
            // Scaled up AFTER the blur so the blur's transparent edge falloff lands off-screen
            // instead of ringing the frame in grey.
            modifier = Modifier.fillMaxSize().scale(1.2f).blur(24.dp),
            contentScale = ContentScale.Crop,
        )
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.4f)))
    }
}

/** Full-frame story renderer: a still image, or a looping muted-aware video. */
@Composable
fun StoryMediaFrame(
    localPath: String,
    isVideo: Boolean,
    paused: Boolean,
    muted: Boolean,
    modifier: Modifier = Modifier,
) {
    // Neutral rather than pure black underneath, for the frame we could not read at all.
    Box(modifier.fillMaxSize().background(Color(0xFF121212)), contentAlignment = Alignment.Center) {
        StoryBackdrop(localPath, isVideo)
        if (!isVideo) {
            val configuration = LocalConfiguration.current
            val density = LocalDensity.current
            val targetW = with(density) { configuration.screenWidthDp.dp.roundToPx() }
            val targetH = with(density) { configuration.screenHeightDp.dp.roundToPx() }
            val bmp = rememberStoryThumbnail(localPath, isVideo = false, targetWidthPx = targetW, targetHeightPx = targetH)
            if (bmp != null) Image(bmp, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        } else {
            // Video: Media3 ExoPlayer, the same stack Clips uses. VideoView exposed no volume control
            // after preparation, so a mute toggle could not reach a story already on screen.
            val context = LocalContext.current
            val player = remember(localPath) {
                ExoPlayer.Builder(context).build().apply {
                    setMediaItem(MediaItem.fromUri(Uri.fromFile(File(localPath))))
                    repeatMode = Player.REPEAT_MODE_ONE
                    volume = if (muted) 0f else 1f
                    playWhenReady = !paused
                    prepare()
                }
            }
            LaunchedEffect(player, muted) { player.volume = if (muted) 0f else 1f }
            LaunchedEffect(player, paused) { player.playWhenReady = !paused }
            DisposableEffect(player) { onDispose { player.release() } }
            AndroidView(
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        useController = false
                        this.player = player
                        // The shutter defaults to opaque black and covers the video rect until the
                        // first frame lands — over the backdrop that reads as the black flash the
                        // backdrop exists to remove.
                        setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
                        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                    }
                },
                update = { it.player = player },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

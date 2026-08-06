package com.voiid.app.main.stories

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.util.LruCache
import androidx.compose.foundation.Image
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
    val key = localPath?.let { "$it@${targetWidthPx}x$targetHeightPx" }
    var bmp by remember(key) { mutableStateOf(key?.let { thumbCache.get(it) }) }
    LaunchedEffect(key) {
        val p = localPath ?: return@LaunchedEffect
        val k = key ?: return@LaunchedEffect
        if (bmp != null || !File(p).exists()) return@LaunchedEffect
        val decoded = withContext(Dispatchers.IO) {
            runCatching {
                if (isVideo) videoFrame(p, targetWidthPx, targetHeightPx)
                else decodeSampled(p, targetWidthPx, targetHeightPx)
            }.getOrNull()
        }
        if (decoded != null) { val ib = decoded.asImageBitmap(); thumbCache.put(k, ib); bmp = ib }
    }
    return bmp
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
    if (!isVideo) {
        val configuration = LocalConfiguration.current
        val density = LocalDensity.current
        val targetW = with(density) { configuration.screenWidthDp.dp.roundToPx() }
        val targetH = with(density) { configuration.screenHeightDp.dp.roundToPx() }
        val bmp = rememberStoryThumbnail(localPath, isVideo = false, targetWidthPx = targetW, targetHeightPx = targetH)
        Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            if (bmp != null) Image(bmp, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        }
        return
    }
    // Video: Media3 ExoPlayer, the same stack Clips uses. VideoView exposed no volume control after
    // preparation, so a mute toggle could not reach a story already on screen.
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
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    useController = false
                    this.player = player
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                }
            },
            update = { it.player = player },
            modifier = Modifier.fillMaxSize(),
        )
    }
}

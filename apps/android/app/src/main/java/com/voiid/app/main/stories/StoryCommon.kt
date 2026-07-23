package com.voiid.app.main.stories

import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.widget.VideoView
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
import androidx.compose.ui.viewinterop.AndroidView
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

/** In-memory decoded-frame cache for tray thumbnails, keyed by local file path. */
private val thumbCache = HashMap<String, ImageBitmap>()

/**
 * A decrypted still frame for a local story file (image bytes decoded directly; a video's first
 * frame pulled via MediaMetadataRetriever). Used for tray cells and viewer prefetch. Returns null
 * while loading / on failure so the caller can show a placeholder.
 */
@Composable
fun rememberStoryThumbnail(localPath: String?, isVideo: Boolean): ImageBitmap? {
    var bmp by remember(localPath) { mutableStateOf(localPath?.let { thumbCache[it] }) }
    LaunchedEffect(localPath) {
        val p = localPath ?: return@LaunchedEffect
        if (bmp != null || !File(p).exists()) return@LaunchedEffect
        val decoded = withContext(Dispatchers.IO) {
            runCatching {
                if (isVideo) {
                    MediaMetadataRetriever().use { r -> r.setDataSource(p); r.getFrameAtTime(0) }
                } else {
                    BitmapFactory.decodeFile(p)
                }
            }.getOrNull()
        }
        if (decoded != null) { val ib = decoded.asImageBitmap(); thumbCache[p] = ib; bmp = ib }
    }
    return bmp
}

/** Full-frame story renderer: a still image, or a looping muted-aware VideoView. */
@Composable
fun StoryMediaFrame(
    localPath: String,
    isVideo: Boolean,
    paused: Boolean,
    muted: Boolean,
    modifier: Modifier = Modifier,
) {
    if (!isVideo) {
        val bmp = rememberStoryThumbnail(localPath, isVideo = false)
        Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            if (bmp != null) Image(bmp, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        }
        return
    }
    // Video: a platform VideoView driven by the pause/mute flags. No ExoPlayer dependency exists
    // in this app, and VideoView plays a local MP4 with zero new deps.
    var view by remember { mutableStateOf<VideoView?>(null) }
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        AndroidView(
            factory = { ctx ->
                VideoView(ctx).apply {
                    setVideoPath(localPath)
                    setOnPreparedListener { mp ->
                        mp.isLooping = true
                        mp.setVolume(if (muted) 0f else 1f, if (muted) 0f else 1f)
                        if (!paused) start()
                    }
                    view = this
                }
            },
            update = { vv ->
                if (paused) { if (vv.isPlaying) vv.pause() } else { if (!vv.isPlaying) vv.start() }
            },
            modifier = Modifier.fillMaxSize(),
        )
    }
    DisposableEffect(localPath) { onDispose { view?.stopPlayback() } }
}

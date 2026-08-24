package com.voiid.app.main

import android.content.Context
import android.graphics.BitmapFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import android.media.MediaPlayer
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.components.LocalVoiidHaptics
import kotlinx.coroutines.delay
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.voiid.app.net.ChatEngine
import com.voiid.app.ui.theme.VoiidColor
import java.io.File

/**
 * Encrypted-media rendering: fetch + decrypt the blob via ChatEngine on demand.
 * In-memory cache keyed by the R2 object key so reopening a chat doesn't re-fetch.
 * Mirrors iOS AsyncMediaImage / AsyncVoiceNote.
 */
object MediaCache {
    private val images = HashMap<String, ImageBitmap>()
    private val datas = HashMap<String, ByteArray>()

    // In-memory tier (instant re-render within a process).
    fun image(k: String) = images[k]
    fun putImage(k: String, v: ImageBitmap) { images[k] = v }
    fun data(k: String) = datas[k]

    // Disk tier: DECRYPTED media persisted under the app's private files dir, so a photo/voice
    // note seen once (or one you sent) renders instantly and WITHOUT the network across
    // restarts — the WhatsApp behaviour. The plaintext bytes are cached, so the render path
    // never re-downloads or re-decrypts.
    private fun dir(ctx: Context) = java.io.File(ctx.filesDir, "media").apply { mkdirs() }
    private fun fileFor(ctx: Context, key: String): java.io.File {
        val name = java.security.MessageDigest.getInstance("SHA-256")
            .digest(key.toByteArray()).joinToString("") { "%02x".format(it) }
        return java.io.File(dir(ctx), name)
    }

    /** Bytes from memory → disk (promoting to memory), or null. Disk read should run off the main thread. */
    fun data(ctx: Context, k: String): ByteArray? {
        datas[k]?.let { return it }
        val f = fileFor(ctx, k)
        if (!f.exists()) return null
        val b = runCatching { f.readBytes() }.getOrNull() ?: return null
        datas[k] = b
        return b
    }

    fun putData(ctx: Context, k: String, v: ByteArray) {
        datas[k] = v
        runCatching { fileFor(ctx, k).writeBytes(v) }
    }

    /** Decoded bitmap from memory → disk, or null. Decode should run off the main thread. */
    fun image(ctx: Context, k: String): ImageBitmap? {
        images[k]?.let { return it }
        val b = data(ctx, k) ?: return null
        val bmp = BitmapFactory.decodeByteArray(b, 0, b.size) ?: return null
        val ib = bmp.asImageBitmap()
        images[k] = ib
        return ib
    }

    /** Drop every decrypted byte, memory AND disk (called on sign-out). */
    fun clear(ctx: Context) {
        images.clear(); datas.clear()
        runCatching { dir(ctx).deleteRecursively() }
    }
}

/**
 * Local-first resolve of a media ref to a decoded bitmap — the same cache tiers as
 * [AsyncMediaImage] (memory → disk → network), shared with the full-screen viewer so opening
 * an image never re-downloads what the bubble already showed.
 */
suspend fun loadMediaBitmap(
    context: android.content.Context,
    ref: ChatEngine.MediaRef,
): androidx.compose.ui.graphics.ImageBitmap? = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
    MediaCache.image(context, ref.mediaUrl)?.let { return@withContext it }
    runCatching {
        val bytes = ChatEngine.get(context).fetchMedia(ref)
        MediaCache.putData(context, ref.mediaUrl, bytes)
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
    }.getOrNull()?.also { ib -> MediaCache.putImage(ref.mediaUrl, ib) }
}

@Composable
fun AsyncMediaImage(ref: ChatEngine.MediaRef, onTap: (() -> Unit)? = null) {
    val context = LocalContext.current
    var bitmap by remember(ref.mediaUrl) { mutableStateOf(MediaCache.image(ref.mediaUrl)) }
    var failed by remember(ref.mediaUrl) { mutableStateOf(false) }

    LaunchedEffect(ref.mediaUrl) {
        if (bitmap != null) return@LaunchedEffect
        // Local-first: disk (off the main thread) → only then network. Offline, a photo seen
        // once or one you sent renders straight from disk with no spinner.
        withContext(Dispatchers.IO) { MediaCache.image(context, ref.mediaUrl) }?.let { bitmap = it; return@LaunchedEffect }
        runCatching {
            val bytes = ChatEngine.get(context).fetchMedia(ref)
            MediaCache.putData(context, ref.mediaUrl, bytes)   // persist the plaintext bytes
            val bmp = withContext(Dispatchers.IO) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }
            if (bmp != null) { val ib = bmp.asImageBitmap(); MediaCache.putImage(ref.mediaUrl, ib); bitmap = ib }
            else failed = true
        }.onFailure { failed = true }
    }

    Box(
        Modifier
            .size(220.dp).clip(RoundedCornerShape(12.dp)).background(VoiidColor.accent.copy(alpha = 0.3f))
            .then(if (onTap != null) Modifier.clickable(onClick = onTap) else Modifier),
        Alignment.Center,
    ) {
        val b = bitmap
        when {
            b != null -> Image(b, null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            failed -> Icon(Icons.Default.Image, null, tint = VoiidColor.primary, modifier = Modifier.size(40.dp))
            else -> CircularProgressIndicator(color = VoiidColor.primary)
        }
    }
}

/**
 * A voice note as a SEEKABLE SCRUBBER, not a play button next to decorative bars.
 *
 * It was a plain play/pause icon plus 18 static bars at flat alpha — no progress, no time, and
 * no way to skip back three seconds to catch a word you missed, which is the single most
 * common thing anyone wants from a voice message.
 *
 * @param onOwnBubble the sent bubble is FILLED, so primary-on-primary is unreadable there and
 *                    every colour has to invert. Passing this in is what keeps the same
 *                    component usable on both sides.
 */
@Composable
fun AsyncVoiceNote(ref: ChatEngine.MediaRef?, label: String, onOwnBubble: Boolean = false) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    var bytes by remember(ref?.mediaUrl) { mutableStateOf(ref?.mediaUrl?.let { MediaCache.data(it) }) }
    var playing by remember { mutableStateOf(false) }
    var player by remember { mutableStateOf<MediaPlayer?>(null) }
    var progress by remember { mutableFloatStateOf(0f) }
    var durationMs by remember { mutableIntStateOf(0) }
    var elapsedMs by remember { mutableIntStateOf(0) }

    val tint = if (onOwnBubble) VoiidColor.textOnBubble else VoiidColor.primary
    val trackTint = if (onOwnBubble) VoiidColor.textOnBubble.copy(alpha = 0.35f)
                    else VoiidColor.textSecondary.copy(alpha = 0.4f)
    val metaTint = if (onOwnBubble) VoiidColor.textOnBubble.copy(alpha = 0.7f) else VoiidColor.textSecondary

    LaunchedEffect(ref?.mediaUrl) {
        val r = ref ?: return@LaunchedEffect
        if (bytes != null) return@LaunchedEffect
        // Local-first: disk (off the main thread) → only then network.
        withContext(Dispatchers.IO) { MediaCache.data(context, r.mediaUrl) }?.let { bytes = it; return@LaunchedEffect }
        runCatching { val d = ChatEngine.get(context).fetchMedia(r); MediaCache.putData(context, r.mediaUrl, d); bytes = d }
    }

    /** Build the player lazily, but eagerly enough to know the DURATION before first play —
     *  a scrubber that reads 0:00 until you press play is a scrubber you cannot aim with. */
    fun ensurePlayer(): MediaPlayer? {
        val data = bytes ?: return null
        player?.let { return it }
        return runCatching {
            val f = File.createTempFile("vn", ".m4a", context.cacheDir).apply { writeBytes(data) }
            MediaPlayer().apply {
                setDataSource(f.path); prepare()
                setOnCompletionListener { playing = false; progress = 0f; elapsedMs = 0 }
            }.also { player = it; durationMs = it.duration }
        }.getOrNull()
    }

    LaunchedEffect(bytes) { if (bytes != null) ensurePlayer() }
    DisposableEffect(Unit) { onDispose { player?.release() } }

    // Drive progress from the player itself rather than a wall-clock timer, so a seek or a
    // pause can never desync the bar from the audio.
    LaunchedEffect(playing) {
        while (playing) {
            player?.let { elapsedMs = it.currentPosition; if (it.duration > 0) progress = it.currentPosition / it.duration.toFloat() }
            delay(50)
        }
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.width(210.dp),
    ) {
        Box(
            Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(if (onOwnBubble) VoiidColor.textOnBubble.copy(alpha = 0.18f) else VoiidColor.primary.copy(alpha = 0.12f))
                .clickable(enabled = bytes != null) {
                    haptics.tap()
                    val p = ensurePlayer() ?: return@clickable
                    if (playing) { p.pause(); playing = false } else { p.start(); playing = true }
                },
            contentAlignment = Alignment.Center,
        ) {
            if (bytes == null) {
                CircularProgressIndicator(Modifier.size(16.dp), color = tint, strokeWidth = 2.dp)
            } else {
                Icon(
                    if (playing) Icons.Default.Pause else Icons.Default.PlayArrow, null,
                    tint = tint, modifier = Modifier.size(17.dp),
                )
            }
        }

        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            val barCount = 26
            // Deterministic per-message pattern, seeded from the URL: bars that change on
            // every recomposition read as noise, and two different notes that look identical
            // read as a bug.
            val seed = remember(ref?.mediaUrl) { (ref?.mediaUrl ?: label).hashCode() }
            val heights = remember(seed) {
                val rnd = java.util.Random(seed.toLong())
                List(barCount) { 5 + rnd.nextInt(15) }
            }
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(22.dp)
                    .pointerInput(bytes) {
                        if (bytes == null) return@pointerInput
                        // Tap AND drag both seek. Tap-to-jump is what people try first;
                        // drag is what they use to hunt for a word.
                        detectTapGestures { off ->
                            val p = ensurePlayer() ?: return@detectTapGestures
                            val f = (off.x / size.width).coerceIn(0f, 1f)
                            p.seekTo((f * p.duration).toInt()); progress = f; elapsedMs = p.currentPosition
                        }
                    }
                    .pointerInput(bytes) {
                        if (bytes == null) return@pointerInput
                        detectHorizontalDragGestures { change, _ ->
                            val p = ensurePlayer() ?: return@detectHorizontalDragGestures
                            val f = (change.position.x / size.width).coerceIn(0f, 1f)
                            p.seekTo((f * p.duration).toInt()); progress = f; elapsedMs = p.currentPosition
                        }
                    },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                heights.forEachIndexed { i, h ->
                    val played = i.toFloat() / barCount <= progress
                    Box(
                        Modifier
                            .weight(1f)
                            .height(h.dp)
                            .clip(CircleShape)
                            .background(if (played) tint else trackTint),
                    )
                }
            }
            Text(
                // Elapsed once it has started, total before — the number is only useful if it
                // answers "how much is left".
                if (elapsedMs > 0) timeLabel(elapsedMs) else timeLabel(durationMs),
                style = VoiidFont.rounded(10),
                color = metaTint,
            )
        }
    }
}

private fun timeLabel(ms: Int): String {
    val total = ms / 1000
    return "%d:%02d".format(total / 60, total % 60)
}

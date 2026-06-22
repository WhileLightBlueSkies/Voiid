package com.voiid.app.main

import android.graphics.BitmapFactory
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
    fun image(k: String) = images[k]
    fun putImage(k: String, v: ImageBitmap) { images[k] = v }
    fun data(k: String) = datas[k]
    fun putData(k: String, v: ByteArray) { datas[k] = v }
}

@Composable
fun AsyncMediaImage(ref: ChatEngine.MediaRef) {
    val context = LocalContext.current
    var bitmap by remember(ref.mediaUrl) { mutableStateOf(MediaCache.image(ref.mediaUrl)) }
    var failed by remember(ref.mediaUrl) { mutableStateOf(false) }

    LaunchedEffect(ref.mediaUrl) {
        if (bitmap != null) return@LaunchedEffect
        runCatching {
            val bytes = ChatEngine.get(context).fetchMedia(ref)
            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            if (bmp != null) { val ib = bmp.asImageBitmap(); MediaCache.putImage(ref.mediaUrl, ib); bitmap = ib }
            else failed = true
        }.onFailure { failed = true }
    }

    Box(
        Modifier.size(220.dp).clip(RoundedCornerShape(12.dp)).background(VoiidColor.accent.copy(alpha = 0.3f)),
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

@Composable
fun AsyncVoiceNote(ref: ChatEngine.MediaRef?, label: String) {
    val context = LocalContext.current
    var bytes by remember(ref?.mediaUrl) { mutableStateOf(ref?.mediaUrl?.let { MediaCache.data(it) }) }
    var playing by remember { mutableStateOf(false) }
    var player by remember { mutableStateOf<MediaPlayer?>(null) }

    LaunchedEffect(ref?.mediaUrl) {
        val r = ref ?: return@LaunchedEffect
        if (bytes != null) return@LaunchedEffect
        runCatching { val d = ChatEngine.get(context).fetchMedia(r); MediaCache.putData(r.mediaUrl, d); bytes = d }
    }
    DisposableEffect(Unit) { onDispose { player?.release() } }

    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        IconButton(
            enabled = bytes != null,
            onClick = {
                val data = bytes ?: return@IconButton
                if (playing) { player?.pause(); playing = false } else {
                    if (player == null) {
                        val f = File.createTempFile("vn", ".m4a", context.cacheDir).apply { writeBytes(data) }
                        player = MediaPlayer().apply {
                            setDataSource(f.path); prepare()
                            setOnCompletionListener { playing = false }
                        }
                    }
                    player?.start(); playing = true
                }
            },
        ) {
            Icon(
                if (playing) Icons.Default.Pause else Icons.Default.PlayArrow, null,
                tint = VoiidColor.primary, modifier = Modifier.size(30.dp),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            repeat(18) { i ->
                Box(Modifier.width(2.5.dp).height((6 + (i * 7) % 18).dp).background(VoiidColor.primary.copy(alpha = 0.5f)))
            }
        }
        if (bytes == null) CircularProgressIndicator(Modifier.size(16.dp), color = VoiidColor.primary, strokeWidth = 2.dp)
    }
}

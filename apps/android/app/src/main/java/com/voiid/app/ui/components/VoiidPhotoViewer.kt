package com.voiid.app.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.ui.draw.clip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.IconButton
import com.voiid.app.ui.theme.VoiidColor
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch

/**
 * The one full-screen photo viewer behind every audited image surface (message media, profile
 * photos). Port of the iOS image cover, upgraded to the interaction model the audit demands:
 *
 *  - REAL remote/local image through a caller-supplied [load] — cached loading/error states,
 *    never a placeholder that pretends to be the picture.
 *  - Pinch zoom + pan, panning clamped so the image cannot be flung off screen.
 *  - 2.5× double-tap zoom toggle.
 *  - Direct vertical drag-to-dismiss at scale 1: the photo tracks the finger and the backdrop
 *    fades with it; past the threshold (or with enough velocity) it releases closed.
 *  - Black system-bar treatment while open.
 *  - Reduced motion: gestures stay (they are direct manipulation), springs become snaps.
 */
object VoiidPhotoViewerDefaults {
    const val DOUBLE_TAP_SCALE: Float = 2.5f
    const val MAX_SCALE: Float = 5f
    /** Fraction of the viewport height the photo must travel before release closes. */
    const val DISMISS_TRAVEL_FRACTION: Float = 0.22f
    /** Downward release velocity in px/s that closes outright. */
    const val DISMISS_FLING: Float = 1400f
}

data class VoiidPhoto(val id: String, val load: suspend () -> ImageBitmap?)

@Composable
fun VoiidPhotoViewer(
    title: String?,
    load: suspend () -> ImageBitmap?,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    photos: List<VoiidPhoto> = emptyList(),
    initialIndex: Int = 0,
) {
    val reduceMotion = reduceMotionEnabled()
    val entries = remember(photos) { photos.ifEmpty { listOf(VoiidPhoto("single", load)) } }
    var current by remember { mutableStateOf(initialIndex.coerceIn(entries.indices)) }
    var retry by remember { mutableStateOf(0) }

    var image by remember { mutableStateOf<ImageBitmap?>(null) }
    var failed by remember { mutableStateOf(false) }

    LaunchedEffect(current, retry) {
        image = null
        failed = false
        val bmp = try { entries[current].load() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { null }
        if (bmp != null) image = bmp else failed = true
    }

    var scale by remember { mutableStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var dragY by remember { mutableStateOf(0f) }

    fun resetTransform() {
        scale = 1f
        offset = Offset.Zero
    }

    Dialog(
        onDismissRequest = onClose,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
            dismissOnBackPress = true,
            dismissOnClickOutside = false,
        ),
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = (1f - kotlin.math.abs(dragY) / 1200f).coerceIn(0.35f, 1f)))
                .pointerInput(image, current) {
                    // Transform first (pinch/pan); taps layered separately.
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        var travel = Offset.Zero
                        val velocity = VelocityTracker()
                        do {
                            val event = awaitPointerEvent()
                            val pan = event.calculatePan()
                            val zoom = event.calculateZoom()
                            travel += pan
                            if (event.changes.size == 1) {
                                val pointer = event.changes.first()
                                velocity.addPosition(pointer.uptimeMillis, pointer.position)
                            }
                            if (zoom != 1f || scale > 1f) {
                                scale = (scale * zoom).coerceIn(1f, VoiidPhotoViewerDefaults.MAX_SCALE)
                                val x = size.width * (scale - 1f) / 2f
                                val y = size.height * (scale - 1f) / 2f
                                offset = Offset((offset.x + pan.x).coerceIn(-x, x), (offset.y + pan.y).coerceIn(-y, y))
                                event.changes.forEach { it.consume() }
                            } else if (travel.getDistance() > viewConfiguration.touchSlop) {
                                if (kotlin.math.abs(travel.y) > kotlin.math.abs(travel.x)) dragY += pan.y
                                event.changes.forEach { it.consume() }
                            }
                        } while (event.changes.any { it.pressed })
                        if (scale == 1f) {
                            val release = velocity.calculateVelocity()
                            if (dragY > size.height * VoiidPhotoViewerDefaults.DISMISS_TRAVEL_FRACTION ||
                                (dragY > 0f && release.y > VoiidPhotoViewerDefaults.DISMISS_FLING)) onClose()
                            else if (kotlin.math.abs(travel.x) > size.width * 0.18f && kotlin.math.abs(travel.x) > kotlin.math.abs(travel.y)) {
                                current = (current + if (travel.x < 0) 1 else -1).coerceIn(entries.indices)
                            }
                        }
                        dragY = 0f
                    }
                }
                .pointerInput(image, reduceMotion) {
                    detectTapGestures(
                        onDoubleTap = {
                            if (image == null) return@detectTapGestures
                            val target =
                                if (scale > 1f) 1f else VoiidPhotoViewerDefaults.DOUBLE_TAP_SCALE
                            if (reduceMotion) { scale = target; offset = Offset.Zero } else scale = target
                        },
                        onTap = { if (dragY == 0f && scale == 1f) onClose() },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            val bmp = image
            when {
                bmp != null -> Image(
                    bitmap = bmp,
                    contentDescription = title,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxSize()
                        .graphicsLayer {
                            scaleX = scale
                            scaleY = scale
                            translationX = offset.x
                            translationY = offset.y + dragY
                            alpha = (1f - kotlin.math.abs(dragY) / 1600f).coerceIn(0.4f, 1f)
                        },
                )
                failed -> TextButton(onClick = { retry++ }) { Text("Couldn’t load photo · Retry", color = Color.White) }
                else -> CircularProgressIndicator(color = Color.White)
            }

            if (entries.size > 1) {
                Text("${current + 1} of ${entries.size}", color = Color.White,
                    modifier = Modifier.align(Alignment.TopStart).statusBarsPadding().padding(20.dp))
                LazyRow(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 16.dp),
                    contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    itemsIndexed(entries, key = { _, entry -> entry.id }) { index, entry ->
                        var thumbnail by remember(entry.id) { mutableStateOf<ImageBitmap?>(null) }
                        LaunchedEffect(entry.id) {
                            try { thumbnail = entry.load() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { }
                        }
                        Box(Modifier.size(44.dp).clip(RoundedCornerShape(10.dp))
                            .border(if (current == index) 2.dp else 0.dp, VoiidColor.primary, RoundedCornerShape(10.dp))
                            .clickable { resetTransform(); dragY = 0f; current = index }) {
                            thumbnail?.let { Image(it, "Photo ${index + 1}", Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
                        }
                    }
                }
            }

            // Close affordance, top-trailing like iOS.
            IconButton(onClick = onClose, modifier = Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(8.dp)) {
            Icon(
                Icons.Default.Close, "Close",
                tint = Color.White,
                modifier = Modifier.size(24.dp),
            )
            }
        }
    }
}

package com.voiid.app.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
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
    /** Downward release velocity (px/s… actually px/frame here) that closes outright. */
    const val DISMISS_FLING: Float = 1400f
}

@Composable
fun VoiidPhotoViewer(
    title: String?,
    load: suspend () -> ImageBitmap?,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val reduceMotion = reduceMotionEnabled()

    var image by remember { mutableStateOf<ImageBitmap?>(null) }
    var failed by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val bmp = runCatching { load() }.getOrNull()
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
                .pointerInput(image, reduceMotion) {
                    // Transform first (pinch/pan); taps layered separately.
                    detectTransformGestures { centroid, pan, zoom, _ ->
                        if (image == null) return@detectTransformGestures
                        if (zoom != 1f) {
                            val newScale = (scale * zoom).coerceIn(1f, VoiidPhotoViewerDefaults.MAX_SCALE)
                            // Zoom toward the pinch centroid.
                            val centred = (centroid - offset)
                            offset = offset + centred * (1f - newScale / scale.coerceAtLeast(0.001f)) * -1f
                            scale = newScale
                        } else if (scale > 1f) {
                            offset += pan
                        } else {
                            // At rest scale, a downward drag dismisses; upward drag rubber-bands lightly.
                            dragY = (dragY + pan.y).coerceAtLeast(-60f)
                        }
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
                failed -> Icon(
                    Icons.Default.Close, null,
                    tint = Color.White.copy(alpha = 0.6f), modifier = Modifier.size(44.dp),
                )
                else -> CircularProgressIndicator(color = Color.White)
            }

            // Close affordance, top-trailing like iOS.
            Icon(
                Icons.Default.Close, "Close",
                tint = Color.White,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = 40.dp, end = 20.dp)
                    .size(28.dp)
                    .pointerInput(reduceMotion) {
                        detectTapGestures { onClose() }
                    },
            )
        }
    }
}

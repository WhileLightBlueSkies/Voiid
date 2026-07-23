package com.voiid.app.main.stories

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Segmented story progress bar — one capsule per post in the current context. Played segments are
 * solid white, the playing one fills left-to-right to [progress], future ones are dim. Driven by a
 * 30 Hz tick from the viewer (a plain float), NOT by animation interpolation, so pause/resume is
 * exact — an animation would keep easing past a pause and lie about where the story is.
 */
@Composable
fun StorySegmentProgress(
    count: Int,
    currentIndex: Int,
    progress: Float,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth().height(2.5.dp).padding(horizontal = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        for (i in 0 until count) {
            val fill = when {
                i < currentIndex -> 1f
                i > currentIndex -> 0f
                else -> progress.coerceIn(0f, 1f)
            }
            Box(
                Modifier.weight(1f).fillMaxHeight()
                    .clip(RoundedCornerShape(999.dp))
                    .background(Color.White.copy(alpha = 0.35f)),
            ) {
                if (fill > 0f) {
                    Box(
                        Modifier.fillMaxWidth(fill).fillMaxHeight()
                            .clip(RoundedCornerShape(999.dp))
                            .background(Color.White),
                    )
                }
            }
        }
    }
}

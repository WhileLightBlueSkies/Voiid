package com.voiid.app.ui.components

import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput

/**
 * Makes a full-screen cover OPAQUE TO TOUCH.
 *
 * Compose hit-tests overlapping siblings top-down and stops at the first one that has a
 * pointer-input node under the finger. A cover whose tapped spot is only background has none,
 * so the tap fell THROUGH to the screen underneath — the Games list stayed clickable behind a
 * game. This node claims the whole area without consuming anything, so the cover's own
 * buttons, scrolls and drags still work and nothing below it ever sees the gesture. iOS gets
 * this for free: a presented view owns every touch in its frame.
 */
fun Modifier.blockTouchesBelow(): Modifier = this.pointerInput(Unit) {
    awaitPointerEventScope { while (true) awaitPointerEvent() }
}

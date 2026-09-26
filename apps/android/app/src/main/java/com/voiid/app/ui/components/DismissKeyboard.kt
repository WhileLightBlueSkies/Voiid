package com.voiid.app.ui.components

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager

/**
 * iOS `.scrollDismissesKeyboard` + tap-the-background-to-dismiss: a user scroll anywhere
 * inside, or a tap that nothing else handled, drops the keyboard.
 */
fun Modifier.dismissKeyboardOnScrollOrTap(): Modifier = composed {
    val focus = LocalFocusManager.current
    val connection = remember(focus) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source == NestedScrollSource.UserInput && available != Offset.Zero) focus.clearFocus()
                return Offset.Zero
            }
        }
    }
    this.nestedScroll(connection).pointerInput(focus) { detectTapGestures(onTap = { focus.clearFocus() }) }
}

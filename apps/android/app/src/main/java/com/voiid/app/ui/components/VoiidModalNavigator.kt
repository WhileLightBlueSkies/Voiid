package com.voiid.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.voiid.app.ui.theme.VoiidColor

/**
 * A sheet-local BACK STACK hosted in ONE window — the Compose spelling of keeping Settings and
 * its children inside a single NavigationStack.
 *
 * WHY THIS EXISTS: the audited screens chained sibling full-screen windows (Settings closes,
 * Backup opens), so system Back from Backup exited to the CHAT LIST instead of back to
 * Settings. With the navigator, opening a child PUSHES onto the stack inside the same window;
 * Back POPS to the screen underneath, and only leaving the root route dismisses the window.
 *
 * Routes are lightweight string ids resolved by the caller's [VoiidModalHost] content lambda,
 * so screens stay exactly as they are — only their open/close lambdas change.
 */
class VoiidModalNavigator internal constructor() {
    var stack by mutableStateOf(listOf<String>())
        internal set

    /** The route currently on top, or null when nothing is presented. */
    val current: String? get() = stack.lastOrNull()

    fun push(route: String) {
        stack = stack + route
    }

    fun pop() {
        if (stack.isNotEmpty()) stack = stack.dropLast(1)
    }

    /** Collapse everything above [route] (e.g. after a destructive action upstream). */
    fun popTo(route: String) {
        val i = stack.indexOf(route)
        if (i >= 0) stack = stack.take(i + 1)
    }

    fun closeAll() {
        stack = emptyList()
    }
}

@Composable
fun rememberVoiidModalNavigator(): VoiidModalNavigator = remember { VoiidModalNavigator() }

/**
 * Presents the navigator's top route while the stack is non-empty. System Back pops a child
 * back to its parent; from the ROOT route it dismisses the whole window — which is the
 * behaviour the user expects at each depth.
 */
@Composable
fun VoiidModalHost(
    navigator: VoiidModalNavigator,
    content: @Composable (route: String) -> Unit,
) {
    val route = navigator.current ?: return

    Dialog(
        onDismissRequest = {},
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
            dismissOnBackPress = false,
            dismissOnClickOutside = false,
        ),
    ) {
        androidx.activity.compose.BackHandler(enabled = true) {
            if (navigator.stack.size > 1) navigator.pop() else navigator.closeAll()
        }
        Box(Modifier.fillMaxSize().background(VoiidColor.background)) {
            content(route)
        }
    }
}

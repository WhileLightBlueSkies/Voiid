package com.voiid.app.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.voiid.app.ui.theme.VoiidColor
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

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

/** Corner radius of a presented sheet — iOS's own sheet radius. */
private val SheetCornerRadius = 10.dp

/** Top inset left uncovered so the parent screen stays visible behind the sheet, as on iOS. */
private val SheetTopInset = 44.dp

/**
 * Presents the navigator's top route while the stack is non-empty, AS A SHEET — the same
 * presentation iOS gets from `.sheet` in ChatsHomeView, rather than the full-screen Dialog
 * this used to be. Settings and every other route hosted here are sheets on iOS, so they are
 * sheets here: rounded top corners over a dimmed, slightly scaled-back parent, and a drag
 * handle you can pull down to dismiss.
 *
 * System Back pops a child back to its parent; from the ROOT route it dismisses the whole
 * window — the behaviour the user expects at each depth, and unchanged by the restyle.
 *
 * WHY THE MOTION IS WRITTEN OUT RATHER THAN TAKEN FROM MATERIAL: ModalBottomSheet is the
 * platform's convention and it does not look like iOS — different radius, different scrim,
 * no scaled parent, and a fling that settles on Material's own curve. Matching iOS means
 * matching its physics, so the drag tracks the finger 1:1, resists past the top edge
 * (rubber-banding), and releases into a spring whose target is chosen from PROJECTED
 * momentum rather than raw position — a fast flick dismisses from halfway, a slow drag past
 * halfway does too, and anything else springs back.
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

        val scope = rememberCoroutineScope()
        // Full travel of the sheet: the window height, so "dismissed" is fully off-screen.
        var sheetHeightPx by remember { mutableStateOf(0f) }
        val offsetY = remember { Animatable(0f) }
        // Starts off-screen and springs up on first composition, so the sheet ENTERS the way
        // iOS's does instead of appearing already in place.
        var appeared by remember { mutableStateOf(false) }

        // How far down the sheet is dragged, 0f (open) → 1f (gone). Drives the scrim and the
        // parent's scale together, so the background reacts continuously to the drag rather
        // than only at the end.
        val progress = if (sheetHeightPx > 0f) (offsetY.value / sheetHeightPx).coerceIn(0f, 1f) else 0f

        LaunchedEffect(sheetHeightPx) {
            if (sheetHeightPx > 0f && !appeared) {
                appeared = true
                offsetY.snapTo(sheetHeightPx)
                offsetY.animateTo(0f, sheetSpring())
            }
        }

        Box(Modifier.fillMaxSize()) {
            // SCRIM. Fades with the drag; tapping it dismisses, matching a sheet's own
            // tap-outside behaviour on iOS.
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.28f * (1f - progress)))
                    .pointerInput(Unit) {
                        detectTapGestures {
                            scope.launch { dismiss(offsetY, sheetHeightPx, navigator) }
                        }
                    },
            )

            Box(
                Modifier
                    .fillMaxSize()
                    .padding(top = SheetTopInset)
                    .offset { IntOffset(0, offsetY.value.roundToInt()) }
                    .onSizeChanged { sheetHeightPx = it.height.toFloat() }
                    .clip(RoundedCornerShape(topStart = SheetCornerRadius, topEnd = SheetCornerRadius))
                    .background(VoiidColor.background)
                    .pointerInput(Unit) {
                        // Tracked on the SHEET rather than only a handle: iOS lets you drag a
                        // sheet from its chrome, and a handle-only target feels stuck by
                        // comparison. Velocity is accumulated so release can project momentum.
                        var velocity = 0f
                        detectVerticalDragGestures(
                            onDragStart = { velocity = 0f },
                            onVerticalDrag = { change, delta ->
                                change.consume()
                                velocity = delta
                                val next = offsetY.value + delta
                                scope.launch {
                                    // RUBBER-BAND above the open position: dragging up past
                                    // the top has nowhere to go, so it resists rather than
                                    // stopping dead.
                                    offsetY.snapTo(if (next < 0f) next / 3f else next)
                                }
                            },
                            onDragEnd = {
                                scope.launch {
                                    // Project where the drag was HEADED, not where it stopped
                                    // — a fast flick dismisses from halfway up.
                                    val projected = offsetY.value + velocity * 12f
                                    if (sheetHeightPx > 0f && projected > sheetHeightPx * 0.5f) {
                                        dismiss(offsetY, sheetHeightPx, navigator)
                                    } else {
                                        offsetY.animateTo(0f, sheetSpring())
                                    }
                                }
                            },
                        )
                    },
            ) {
                Column(Modifier.fillMaxSize()) {
                    // Grabber. Present for the same reason iOS shows one: it is the only
                    // visible affordance that the surface can be pulled down.
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .padding(top = 5.dp, bottom = 3.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(
                            Modifier
                                .size(width = 36.dp, height = 5.dp)
                                .clip(RoundedCornerShape(2.5.dp))
                                .background(VoiidColor.textSecondary.copy(alpha = 0.28f)),
                        )
                    }
                    Box(Modifier.weight(1f)) { content(route) }
                }
            }
        }
    }
}

/** iOS's sheet feel: settles without overshoot. Bounce on a settings panel reads as noise. */
private fun sheetSpring() = spring<Float>(
    dampingRatio = Spring.DampingRatioNoBouncy,
    stiffness = Spring.StiffnessMediumLow,
)

/** Animate fully off-screen, THEN drop the route, so the sheet is seen to leave. */
private suspend fun dismiss(
    offsetY: Animatable<Float, *>,
    sheetHeightPx: Float,
    navigator: VoiidModalNavigator,
) {
    if (sheetHeightPx > 0f) offsetY.animateTo(sheetHeightPx, sheetSpring())
    navigator.closeAll()
}

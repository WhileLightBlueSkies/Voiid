package com.voiid.app.ui.components

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * The app's overflow / attach menu.
 *
 * WHY THIS EXISTS INSTEAD OF `androidx.compose.material3.DropdownMenu`
 * --------------------------------------------------------------------
 * The M3 menu is a Material component wearing Material's clothes: its own surface colour and
 * tonal elevation overlay, its own 4dp corner, its own typography, and 48dp rows sized for
 * Material's density rather than this app's. Dropped into a screen built from [VoiidColor]
 * and [VoiidFont] it reads as a foreign object — a grey slab with the wrong type in it.
 *
 * The app had BOTH failure modes at once, which is what made it look broken rather than
 * merely plain. ChatsHomeView re-styled every item by hand — `VoiidFont.rounded(15)` and a
 * tint repeated on each row, container colour set on the menu — while ChatDetailView passed
 * nothing at all. So the same gesture produced two different-looking menus depending on
 * which screen you were on, and neither matched the sheets and cards around them.
 *
 * Per-call-site styling cannot fix that. It repeats on every item (easy to forget one, and
 * one unstyled row is what the eye lands on), and it cannot reach the container's shape,
 * padding, elevation or entry animation at all.
 *
 * WHAT THIS DOES DIFFERENTLY
 * --------------------------
 *  * `VoiidRadius.lg` corners, a hairline border and a soft shadow — the same treatment the
 *    sheets and cards use, so a menu looks like it belongs to the same app.
 *  * Scales and fades in FROM THE CORNER IT IS ANCHORED TO, so the menu visibly comes out of
 *    the button that opened it rather than appearing over it.
 *  * Rows carry the app's press feedback: spring scale plus a soft haptic, matching
 *    [softClickable]. M3's ripple is the single most recognisably "default Android" thing
 *    on screen and this app removes it everywhere else.
 *  * Destructive items get [VoiidColor.error] from one flag instead of each caller
 *    remembering to tint both the label and the icon.
 *
 * Built on [Popup] rather than wrapping DropdownMenu because the parts that look wrong —
 * the surface, the shape, the animation — are exactly the parts DropdownMenu does not
 * expose.
 */
@Composable
fun VoiidMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    /** Nudge from the anchor. Defaults to a small drop so the menu clears the button. */
    offset: DpOffset = DpOffset(0.dp, 6.dp),
    /** Which corner the menu grows from. Right-aligned for toolbar overflow, left for attach. */
    alignEnd: Boolean = true,
    content: @Composable ColumnScopeMarker.() -> Unit,
) {
    if (!expanded) return

    // Driven by a LaunchedEffect rather than read straight from `expanded`: the popup is only
    // composed while expanded, so the animation needs a value that starts at 0 on the first
    // frame and is set to 1 immediately after. Reading `expanded` would give 1 on frame one
    // and there would be nothing to animate.
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { shown = true }

    val scale by animateFloatAsState(
        targetValue = if (shown) 1f else 0.92f,
        animationSpec = spring(dampingRatio = 0.72f, stiffness = Spring.StiffnessMediumLow),
        label = "menuScale",
    )
    val alpha by animateFloatAsState(
        targetValue = if (shown) 1f else 0f,
        animationSpec = tween(durationMillis = 120),
        label = "menuAlpha",
    )

    Popup(
        alignment = if (alignEnd) Alignment.TopEnd else Alignment.TopStart,
        offset = IntOffset(0, 0),
        onDismissRequest = onDismissRequest,
        properties = PopupProperties(focusable = true),
    ) {
        Column(
            modifier
                .padding(top = offset.y, start = offset.x)
                .graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                    this.alpha = alpha
                    // Grow from the anchored corner, so the menu reads as coming OUT of the
                    // button rather than materialising on top of it.
                    transformOrigin = TransformOrigin(
                        if (alignEnd) 1f else 0f, 0f,
                    )
                }
                .shadow(14.dp, RoundedCornerShape(VoiidRadius.lg), clip = false)
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.divider.copy(alpha = 0.5f), RoundedCornerShape(VoiidRadius.lg))
                .widthIn(min = 200.dp, max = 280.dp)
                .padding(vertical = 6.dp),
        ) {
            ColumnScopeMarker.content()
        }
    }
}

/** Scope marker so only menu rows can be placed in a [VoiidMenu]. */
object ColumnScopeMarker

/**
 * One row of a [VoiidMenu].
 *
 * `destructive` tints the label AND the icon from a single flag. Doing it per call site is
 * how you end up with a red "Delete" beside a grey trash can — the two were set in different
 * places and only one got updated.
 */
@Composable
fun ColumnScopeMarker.VoiidMenuItem(
    text: String,
    icon: ImageVector? = null,
    destructive: Boolean = false,
    enabled: Boolean = true,
    /**
     * Marks the item as the current choice in a menu that picks ONE of a set (the call
     * screen's audio route, for instance). The row shows a tick in the accent colour and
     * sets the label semibold, so the state reads at a glance and does not depend on colour
     * alone.
     *
     * Null means the menu is a list of actions rather than a choice, and no space is
     * reserved for a tick. That is the difference between "what can I do here" and "which
     * one am I on" — worth keeping distinct rather than always reserving the column.
     */
    selected: Boolean? = null,
    onClick: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.97f else 1f,
        animationSpec = spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMediumLow),
        label = "menuItemScale",
    )
    LaunchedEffect(pressed) { if (pressed) haptics.soft() }

    val tint: Color = when {
        !enabled -> VoiidColor.textSecondary.copy(alpha = 0.45f)
        destructive -> VoiidColor.error
        else -> VoiidColor.textPrimary
    }

    Row(
        Modifier
            .fillMaxWidth()
            .scale(scale)
            .alpha(if (pressed) 0.9f else 1f)
            .clip(RoundedCornerShape(VoiidRadius.sm))
            .pressableRow(interaction, enabled) { onClick() }
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // A selected row swaps its own icon for a tick — the checkmark IS the state, so it
        // takes the icon's place rather than crowding in beside it.
        val leading = if (selected == true) Icons.Default.Check else icon
        if (leading != null) {
            Icon(
                leading,
                contentDescription = null,
                tint = if (selected == true) VoiidColor.primary else tint,
                modifier = Modifier.size(19.dp),
            )
            Spacer(Modifier.width(12.dp))
        }
        Text(
            text,
            style = VoiidFont.rounded(
                15,
                if (selected == true) FontWeight.SemiBold else FontWeight.Medium,
            ),
            color = tint,
        )
    }
}

/** A hairline between groups of related items. Indented so it separates rather than divides. */
@Composable
fun ColumnScopeMarker.VoiidMenuDivider() {
    Box(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 4.dp)
            .height(1.dp)
            .background(VoiidColor.divider.copy(alpha = 0.5f)),
    )
}

/**
 * `clickable` without the Material ripple.
 *
 * The scale and haptic above already report the press; a ripple on top of them is both
 * doubled feedback and the most recognisably stock-Android thing on the screen. Named
 * defensively so it cannot be confused with the real `Modifier.clickable` at a glance.
 */
private fun Modifier.pressableRow(
    interaction: MutableInteractionSource,
    enabled: Boolean,
    onClick: () -> Unit,
): Modifier = this.clickable(
    interactionSource = interaction,
    indication = null,
    enabled = enabled,
    onClick = onClick,
)

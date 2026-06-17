package com.voiid.app.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * Apple-grade tactile feedback (scale + dim + soft haptic on press) — the Compose port of
 * iOS `SoftPressStyle`. Apply to any tappable element.
 */
@Composable
fun Modifier.softClickable(
    scale: Float = 0.96f,
    enabled: Boolean = true,
    onClick: () -> Unit,
): Modifier {
    val haptics = LocalVoiidHaptics.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val s by animateFloatAsState(
        targetValue = if (pressed) scale else 1f,
        animationSpec = spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMediumLow),
        label = "softPressScale",
    )
    LaunchedEffect(pressed) { if (pressed) haptics.soft() }
    return this
        .scale(s)
        .alpha(if (pressed) 0.9f else 1f)
        .clickable(
            interactionSource = interaction,
            indication = null,
            enabled = enabled,
            onClick = onClick,
        )
}

/**
 * Tap with NO Material ripple and no press-scale — iOS plain `Button`/`Button(.plain)` behavior.
 * Use for list rows, icon buttons, and links where iOS shows no ripple. (For the tactile
 * scale+haptic press, use [softClickable] instead.)
 */
@Composable
fun Modifier.noRippleClickable(enabled: Boolean = true, onClick: () -> Unit): Modifier {
    val interaction = remember { MutableInteractionSource() }
    return this.clickable(
        interactionSource = interaction,
        indication = null,
        enabled = enabled,
        onClick = onClick,
    )
}

/** The dark-plum pill button seen on every onboarding screen — iOS `VoiidPrimaryButton`. */
@Composable
fun VoiidPrimaryButton(
    title: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(64.dp)
            .alpha(if (enabled) 1f else 0.5f)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.primary)
            .softClickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = VoiidFont.headline, color = VoiidColor.textOnPrimary)
    }
}

/** Text field (fill #FCF4F8, border #E3BED8, focus = primary) — iOS `VoiidTextField`. */
@Composable
fun VoiidTextField(
    placeholder: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    keyboardType: KeyboardType = KeyboardType.Text,
    radius: Dp = VoiidRadius.md,
    height: Dp = 61.dp,
) {
    VoiidStyledField(
        value = value,
        onValueChange = onValueChange,
        placeholder = placeholder,
        modifier = modifier.fillMaxWidth(),
        textStyle = VoiidFont.body,
        keyboardType = keyboardType,
        radius = radius,
        height = height,
        horizontalPadding = VoiidSpacing.md,
    )
}

/**
 * Shared brand text-field renderer (rounded fill + focus-aware border). Powers both the
 * generic [VoiidTextField] and the pill fields used across onboarding.
 */
@Composable
fun VoiidStyledField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    textStyle: TextStyle = VoiidFont.body,
    keyboardType: KeyboardType = KeyboardType.Text,
    radius: Dp = VoiidRadius.md,
    height: Dp = 61.dp,
    horizontalPadding: Dp = VoiidSpacing.lg,
    singleLine: Boolean = true,
) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(radius)
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = singleLine,
        textStyle = textStyle.merge(TextStyle(color = VoiidColor.textPrimary)),
        cursorBrush = androidx.compose.ui.graphics.SolidColor(VoiidColor.primary),
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        modifier = modifier
            .height(height)
            .clip(shape)
            .background(VoiidColor.fieldFill)
            .border(1.dp, if (focused) VoiidColor.primary else VoiidColor.fieldBorder, shape)
            .onFocusChanged { focused = it.isFocused }
            .padding(horizontal = horizontalPadding),
        decorationBox = { inner ->
            Box(contentAlignment = Alignment.CenterStart) {
                if (value.isEmpty()) {
                    Text(placeholder, style = textStyle, color = VoiidColor.placeholder)
                }
                inner()
            }
        },
    )
}

/** Circular/rounded avatar with the "voiid" placeholder — iOS `VoiidAvatar`. */
@Composable
fun VoiidAvatar(
    size: Dp,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.fieldFill),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "voiid",
            style = VoiidFont.rounded((size.value * 0.28f).toInt().coerceAtLeast(8),
                androidx.compose.ui.text.font.FontWeight.SemiBold),
            color = VoiidColor.textSecondary.copy(alpha = 0.5f),
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * iOS-style sliding switch (51×31 track, 27 thumb that slides) — replaces the Material `Switch`
 * so the off state is a neutral grey pill (not pink) and the thumb is constant-size, matching the
 * native iOS `Toggle`.
 */
@Composable
fun VoiidToggle(checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val thumbX by animateDpAsState(if (checked) 20.dp else 0.dp, label = "toggleThumb")
    val track by animateColorAsState(
        if (checked) VoiidColor.primary else Color(0xFFE9E9EA), label = "toggleTrack",
    )
    Box(
        Modifier
            .size(width = 51.dp, height = 31.dp)
            .clip(CircleShape)
            .background(track)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) { haptics.selection(); onCheckedChange(!checked) }
            .padding(2.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Box(
            Modifier
                .offset(x = thumbX)
                .size(27.dp)
                .shadow(1.dp, CircleShape)
                .clip(CircleShape)
                .background(Color.White),
        )
    }
}

/**
 * Circular "glass" back button matching iOS 26's native navigation back chevron (white circle +
 * chevron + soft shadow). Used by the full-screen main views (contact/group profile).
 */
@Composable
fun VoiidCircleBack(onBack: () -> Unit, modifier: Modifier = Modifier) {
    val haptics = LocalVoiidHaptics.current
    Box(
        modifier = modifier.height(52.dp).padding(start = 16.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Box(
            modifier = Modifier
                .size(38.dp)
                .shadow(6.dp, CircleShape, clip = false)
                .clip(CircleShape)
                .background(Color.White)
                .softClickable(scale = 0.9f) { haptics.tap(); onBack() },
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, "Back",
                tint = VoiidColor.textPrimary, modifier = Modifier.size(26.dp))
        }
    }
}

/** The faint "voiid" wordmark placeholder (Urbanist) used in grid cards / create-profile. */
@Composable
fun VoiidWordmark(
    fontSize: Int,
    modifier: Modifier = Modifier,
    color: Color = VoiidColor.textSecondary,
    alpha: Float = 0.22f,
) {
    Text(
        "voiid",
        style = VoiidFont.logo(fontSize),
        color = color.copy(alpha = alpha),
        modifier = modifier,
    )
}

/**
 * Bouncy emoji button (iOS `BouncyEmojiStyle`): scales up to 1.4× while pressed with a springy
 * pop. Use for the reaction-pill emojis and the emoji-picker grid cells.
 */
@Composable
fun Modifier.bouncyClickable(onClick: () -> Unit): Modifier {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val s by animateFloatAsState(
        targetValue = if (pressed) 1.4f else 1f,
        animationSpec = spring(dampingRatio = 0.5f, stiffness = Spring.StiffnessMedium),
        label = "bouncyEmoji",
    )
    return this
        .scale(s)
        .clickable(interactionSource = interaction, indication = null, onClick = onClick)
}

/**
 * Zoomable fullscreen profile-photo viewer (iOS `ProfilePhotoViewer`): tap a name/avatar to open;
 * double-tap to zoom 2.5×, tap the ✕ to close. Placeholder shows the faint "voiid" wordmark.
 */
@Composable
fun ProfilePhotoViewer(title: String, onClose: () -> Unit) {
    var scale by remember { mutableFloatStateOf(1f) }
    val animScale by animateFloatAsState(scale, spring(dampingRatio = 0.7f), label = "photoZoom")
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .size(280.dp)
                .scale(animScale)
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.fieldFill)
                .pointerInput(Unit) {
                    detectTapGestures(onDoubleTap = { scale = if (scale > 1f) 1f else 2.5f })
                },
            contentAlignment = Alignment.Center,
        ) {
            VoiidWordmark(fontSize = 48, alpha = 0.3f)
        }
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().align(Alignment.TopCenter).padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(title, style = VoiidFont.rounded(17, FontWeight.SemiBold), color = Color.White)
            Spacer(Modifier.weight(1f))
            Icon(
                Icons.Default.Close, "Close", tint = Color.White,
                modifier = Modifier.size(28.dp).clickable { onClose() },
            )
        }
    }
}

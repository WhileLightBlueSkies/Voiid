package com.voiid.app.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
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
/**
 * THE shared press springs, calibrated to the iOS specs (audit design-system table):
 * soft press = response 0.30s / damping 0.6; tab press = response 0.22s / damping 0.7.
 * Spring stiffness from a SwiftUI response R is (2π/R)² — 440 and 815 here — so every
 * platform draws the same press curve instead of each site guessing a Material constant.
 */
object VoiidMotion {
    val softPress = spring<Float>(dampingRatio = 0.6f, stiffness = 440f)
    val tabPress = spring<Float>(dampingRatio = 0.7f, stiffness = 815f)

    /**
     * iOS `.easeOut(duration:)` is cubic-bezier(0, 0, 0.58, 1) — NOT Compose's
     * `FastOutSlowInEasing`, which eases in as well and reads slower off the press.
     */
    val easeOut = androidx.compose.animation.core.CubicBezierEasing(0f, 0f, 0.58f, 1f)

    /** The community tab bar and the member filter chips: `.easeOut(duration: 0.18)`. */
    fun <T> easeOut180() = tween<T>(durationMillis = 180, easing = easeOut)
}

/**
 * The Compose port of iOS `PressableButtonStyle` (Onboarding/OnboardingKit.swift:427):
 * `scaleEffect(pressed ? 0.97 : 1)` with `.easeOut(duration: 0.16)`.
 *
 * DELIBERATELY NOT [softClickable], which is a different iOS style (`SoftPressStyle`) and
 * differs in three ways that are visible side by side: it scales to 0.96 not 0.97, it dims
 * to 90% alpha, and it fires a haptic on PRESS. `PressableButtonStyle` does none of those —
 * the haptic belongs to the action, so callers fire it themselves inside [onClick].
 */
@Composable
fun Modifier.pressableClickable(
    enabled: Boolean = true,
    onClick: () -> Unit,
): Modifier {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val s by animateFloatAsState(
        targetValue = if (pressed) 0.97f else 1f,
        animationSpec = tween(durationMillis = 160, easing = VoiidMotion.easeOut),
        label = "pressableScale",
    )
    return this
        .scale(s)
        .clickable(
            interactionSource = interaction,
            indication = null,
            enabled = enabled,
            onClick = onClick,
        )
}

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
        animationSpec = VoiidMotion.softPress,
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

/** Text field (fieldFill / fieldBorder tokens, focus = primary) — iOS `VoiidTextField`. */
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
        if (checked) VoiidColor.primary else VoiidColor.fieldBorder, label = "toggleTrack",
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
 * Zoomable fullscreen profile-photo viewer (iOS `ProfilePhotoViewer`).
 *
 * With a [photoRef] the REAL image renders through [VoiidPhotoViewer] — pinch + pan with
 * bounds, 2.5× double-tap, drag-to-dismiss, cached loading/failure states — resolved through
 * the same local-first avatar cache every face in the app uses, so opening it never
 * re-downloads what the profile already showed. Without one, the faint wordmark placeholder
 * remains (groups have no photo to show).
 */
@Composable
fun ProfilePhotoViewer(title: String, onClose: () -> Unit, photoRef: String? = null) {
    val context = androidx.compose.ui.platform.LocalContext.current
    if (photoRef != null) {
        com.voiid.app.ui.components.VoiidPhotoViewer(
            title = title,
            load = { com.voiid.app.net.AvatarCache.resolve(context, photoRef) },
            onClose = onClose,
        )
        return
    }
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

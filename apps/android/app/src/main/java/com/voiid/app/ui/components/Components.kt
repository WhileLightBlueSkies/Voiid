package com.voiid.app.ui.components

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.LocalTextStyle
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
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
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

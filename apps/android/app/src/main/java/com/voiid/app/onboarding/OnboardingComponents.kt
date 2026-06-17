package com.voiid.app.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/** Shared building blocks for the onboarding screens (kept close to the iOS layout). */

val PILL_HEIGHT: Dp = 64.dp

/** Screen scaffold: brand background, system-bar + IME padding, tap-outside dismisses keyboard. */
@Composable
fun OnbScaffold(
    showBack: Boolean,
    onBack: () -> Unit,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    val focus = LocalFocusManager.current
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .pointerInput(Unit) { detectTapGestures { focus.clearFocus() } },
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding(),
        ) {
            if (showBack) OnbBackBar(onBack)
            content()
        }
    }
}

@Composable
fun OnbBackBar(onBack: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    // iOS 26 renders the system back button as a circular "glass" chip (white circle + chevron +
    // soft shadow). Match that instead of a bare Material arrow.
    Box(
        modifier = Modifier.height(52.dp).padding(start = 16.dp),
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

/** Accent pill button (the pink "Continue"/"Sign up" pill across onboarding). */
@Composable
fun OnbAccentButton(
    title: String,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(PILL_HEIGHT)
            .alpha(if (enabled) 1f else 0.55f)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(VoiidColor.accent)
            .softClickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = VoiidFont.rounded(18, FontWeight.Medium), color = VoiidColor.textPrimary)
    }
}

/** Pink-pill text field used by Phone / Signup. */
@Composable
fun OnbPillField(
    placeholder: String,
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    keyboardType: KeyboardType = KeyboardType.Text,
    textStyle: TextStyle = VoiidFont.rounded(17),
) {
    val shape = RoundedCornerShape(VoiidRadius.pill)
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        textStyle = textStyle.merge(TextStyle(color = VoiidColor.textPrimary)),
        cursorBrush = SolidColor(VoiidColor.primary),
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        // iOS onboarding pill fields keep a static pink border (no focus ring) — match that.
        modifier = modifier
            .height(PILL_HEIGHT)
            .clip(shape)
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.fieldBorder, shape)
            .padding(horizontal = 24.dp),
        decorationBox = { inner ->
            Box(contentAlignment = Alignment.CenterStart) {
                if (value.isEmpty()) Text(placeholder, style = textStyle, color = VoiidColor.placeholder)
                inner()
            }
        },
    )
}

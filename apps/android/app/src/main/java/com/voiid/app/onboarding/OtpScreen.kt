package com.voiid.app.onboarding

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/** Onboarding — 6-digit OTP verification (Figma Screen-3). Port of `OTPScreen.swift`. */
@Composable
fun OtpScreen(
    onBack: () -> Unit,
    onContinue: () -> Unit,
    phoneNumber: String = "+91 91234567890",
) {
    val haptics = LocalVoiidHaptics.current
    val focus = LocalFocusManager.current
    val length = 6
    var code by remember { mutableStateOf("") }
    var focused by remember { mutableStateOf(false) }
    val fr = remember { androidx.compose.ui.focus.FocusRequester() }
    val complete = code.length == length

    OnbScaffold(showBack = true, onBack = onBack) {
        Spacer(Modifier.height(24.dp))
        Text("Verify your number", style = VoiidFont.rounded(22, FontWeight.Bold),
            color = VoiidColor.textPrimary, modifier = Modifier.padding(horizontal = 24.dp))
        Text("We sent a 6-digit code to $phoneNumber", style = VoiidFont.rounded(14),
            color = VoiidColor.textSecondary, modifier = Modifier.padding(horizontal = 24.dp).padding(top = 6.dp))

        // Hidden field captures all input; decorationBox renders the display circles.
        BasicTextField(
            value = code,
            onValueChange = { newVal ->
                val digits = newVal.filter(Char::isDigit).take(length)
                if (digits != code) {
                    code = digits
                    if (digits.isNotEmpty()) haptics.selection()
                    if (digits.length == length) focus.clearFocus()
                }
            },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            // Text + cursor are invisible; the display circles below render the digits.
            textStyle = TextStyle(color = Color.Transparent),
            cursorBrush = SolidColor(Color.Transparent),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(top = 32.dp)
                .focusRequester(fr)
                .onFocusChanged { focused = it.isFocused },
            decorationBox = { innerTextField ->
                Box {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        for (i in 0 until length) OtpCircle(i, code, focused, length)
                    }
                    // Transparent input overlay keeps the IME attached + captures taps.
                    Box(Modifier.matchParentSize()) { innerTextField() }
                }
            },
        )
        LaunchedFocus(fr)

        TextButton(onClick = { haptics.tap() }, modifier = Modifier.padding(horizontal = 16.dp, vertical = 0.dp).padding(top = 16.dp)) {
            Text("Resend code", style = VoiidFont.rounded(14, FontWeight.Medium), color = VoiidColor.primary)
        }

        Spacer(Modifier.weight(1f))

        OnbAccentButton(
            title = "Continue",
            enabled = complete,
            modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp),
        ) { haptics.success(); onContinue() }
    }
}

@Composable
private fun RowScope.OtpCircle(i: Int, code: String, keyboardUp: Boolean, length: Int) {
    val activeIndex = minOf(code.length, length - 1)
    val isActive = keyboardUp && i == activeIndex && code.length < length
    val filled = i < code.length
    val scale by animateFloatAsState(
        if (isActive) 1.06f else 1f,
        spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMedium),
        label = "otpScale",
    )
    val digit = if (i < code.length) code[i].toString() else ""
    Box(
        modifier = Modifier
            .weight(1f)
            .height(52.dp)
            .scale(scale)
            .clip(CircleShape)
            .background(VoiidColor.fieldFill)
            .border(
                width = if (isActive) 2.dp else 1.dp,
                color = if (isActive || filled) VoiidColor.primary else VoiidColor.fieldBorder,
                shape = CircleShape,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Text(digit, style = VoiidFont.rounded(22, FontWeight.SemiBold), color = VoiidColor.textPrimary)
    }
}

@Composable
private fun LaunchedFocus(fr: androidx.compose.ui.focus.FocusRequester) {
    androidx.compose.runtime.LaunchedEffect(Unit) {
        // small delay so the field is attached before requesting focus / showing the keyboard
        kotlinx.coroutines.delay(150)
        runCatching { fr.requestFocus() }
    }
}

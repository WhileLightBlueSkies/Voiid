package com.voiid.app.onboarding

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
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
    session: com.voiid.app.model.AppSession,
    phoneE164: String,
    verificationId: String,
    onBack: () -> Unit,
    onContinue: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val focus = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    val length = 6
    var code by remember { mutableStateOf("") }
    var focused by remember { mutableStateOf(false) }
    var verifying by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    val fr = remember { androidx.compose.ui.focus.FocusRequester() }
    val complete = code.length == length
    val phoneNumber = phoneE164

    // Verify the code with Firebase, then exchange the Firebase ID token for our
    // JWT. (Firebase sent the SMS on the previous screen.)
    fun verify() {
        if (verifying) return
        verifying = true; errorText = null
        scope.launch {
            try {
                val idToken = com.voiid.app.net.FirebasePhoneAuth.verify(verificationId, code)
                val profileComplete = session.auth.loginWithFirebase(idToken)
                haptics.success()
                // Returning user (profile already complete) → straight to the app;
                // new user → continue to Signup/Profile.
                if (profileComplete) session.completeOnboarding() else onContinue()
            } catch (e: Exception) {
                errorText = (e as? com.voiid.app.net.ApiError)?.message ?: "Invalid or expired code."
                haptics.tap()
            }
            verifying = false
        }
    }

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

        // iOS: plain Button at horizontal padding 24, no ripple. Match (no Material TextButton).
        Text(
            "Resend code",
            style = VoiidFont.rounded(14, FontWeight.Medium),
            color = VoiidColor.primary,
            modifier = Modifier
                .padding(horizontal = 24.dp)
                .padding(top = 16.dp)
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) { haptics.tap() },
        )

        errorText?.let {
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                modifier = Modifier.padding(horizontal = 24.dp).padding(top = 8.dp))
        }

        Spacer(Modifier.weight(1f))

        OnbAccentButton(
            title = if (verifying) "Verifying…" else "Continue",
            enabled = complete && !verifying,
            modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp),
        ) { verify() }
    }
}

@Composable
private fun RowScope.OtpCircle(i: Int, code: String, keyboardUp: Boolean, length: Int) {
    val activeIndex = minOf(code.length, length - 1)
    val isActive = keyboardUp && i == activeIndex && code.length < length
    val filled = i < code.length
    val scale by animateFloatAsState(
        if (isActive) 1.06f else 1f,
        // Match iOS .spring(response: 0.3, dampingFraction: 0.6) — StiffnessMedium (1500)
        // was too snappy; MediumLow (~400) matches the iOS feel.
        spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMediumLow),
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

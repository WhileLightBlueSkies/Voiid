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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.isActive
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
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.withStyle
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
    /** Called instead of [onContinue] when a RETURNING user verifies — routes through the
     *  Verified screen before entering the app. Mirrors iOS `onExistingUser`. */
    onVerifiedExistingUser: () -> Unit = {},
) {
    val haptics = LocalVoiidHaptics.current
    val focus = LocalFocusManager.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    val length = 6
    // Firebase SMS codes stay valid for 120s (iOS `validFor`).
    val validForSeconds = 120
    var code by remember { mutableStateOf("") }
    var focused by remember { mutableStateOf(false) }
    var verifying by remember { mutableStateOf(false) }
    var resending by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    // The LIVE verificationID. Starts as the one passed in and is REPLACED by a resend —
    // verifying against the original id after a resend fails, because Firebase invalidates it.
    var activeVerificationId by remember { mutableStateOf(verificationId) }
    // Wall-clock deadline for the current code; 0 = not started yet.
    var deadlineAt by remember { mutableStateOf(0L) }
    var remainingSeconds by remember { mutableIntStateOf(validForSeconds) }
    // Non-null once a returning user logs in AND their account has a server backup:
    // we show the restore flow instead of dropping straight into the app.
    var restoreMeta by remember { mutableStateOf<com.voiid.app.net.BackupService.BackupMeta?>(null) }
    val fr = remember { androidx.compose.ui.focus.FocusRequester() }
    val complete = code.length == length
    val phoneNumber = phoneE164

    fun startCountdown() {
        deadlineAt = System.currentTimeMillis() + validForSeconds * 1000L
        remainingSeconds = validForSeconds
    }

    // One tick per second while a code is live; settles at 0 when it expires.
    androidx.compose.runtime.LaunchedEffect(deadlineAt) {
        if (deadlineAt == 0L) return@LaunchedEffect
        while (isActive) {
            val remaining = ((deadlineAt - System.currentTimeMillis()) / 1000L).toInt().coerceAtLeast(0)
            remainingSeconds = remaining
            if (remaining <= 0) break
            kotlinx.coroutines.delay(1000)
        }
    }

    fun focusCodeField() {
        runCatching { fr.requestFocus() }
    }

    fun findActivity(): android.app.Activity? {
        var ctx = context
        while (ctx is android.content.ContextWrapper) {
            if (ctx is android.app.Activity) return ctx
            ctx = ctx.baseContext
        }
        return null
    }

    // Ask Firebase for a new code. THE NEW verificationId REPLACES THE OLD ONE — Firebase
    // invalidates the previous id when it issues a fresh code, so verifying against the id
    // this screen was constructed with would fail for every user who tapped Resend.
    fun resend() {
        if (resending || verifying) return
        resending = true; errorText = null
        scope.launch {
            try {
                val activity = findActivity()
                    ?: throw IllegalStateException("Could not start verification from this screen.")
                val newId = com.voiid.app.net.FirebasePhoneAuth.sendCode(activity, phoneNumber)
                activeVerificationId = newId
                code = ""
                startCountdown()
                focusCodeField()
                haptics.success()
            } catch (e: Exception) {
                errorText = e.message ?: "Couldn't send a new code. Try again."
                haptics.error()
            }
            resending = false
        }
    }

    // Verify the code with Firebase, then exchange the Firebase ID token for our
    // JWT. (Firebase sent the SMS on the previous screen.)
    fun verify() {
        if (verifying) return
        verifying = true; errorText = null
        scope.launch {
            try {
                val idToken = com.voiid.app.net.FirebasePhoneAuth.verify(activeVerificationId, code)
                val profileComplete = session.auth.loginWithFirebase(idToken)
                // The verified number is the ONLY place we ever see it: the API never returns
                // a phone number (privacy). Keep it on our own row so Settings can show it.
                session.updateProfile(phoneE164 = phoneNumber)
                session.loadProfile()
                // Publish this device's E2E identity + prekeys (needed for chat).
                runCatching { com.voiid.app.net.E2EManager.get(context).bootstrap() }
                haptics.success()
                // Returning user (profile already complete) → offer to restore chats
                // if a server backup exists, else through Verified into the app.
                // New user → continue to Signup.
                if (profileComplete) {
                    val meta = runCatching { com.voiid.app.net.BackupManager(context).fetchMeta() }.getOrNull()
                    if (meta != null) restoreMeta = meta else onVerifiedExistingUser()
                } else onContinue()
            } catch (e: Exception) {
                errorText = (e as? com.voiid.app.net.ApiError)?.userMessage ?: "Invalid or expired code."
                haptics.error()
            }
            verifying = false
        }
    }

    // A returning user with a server backup → show the restore flow, then continue
    // through Verified into the app.
    restoreMeta?.let { m ->
        RestoreFlow(
            session = session,
            meta = m,
            onDone = onVerifiedExistingUser,
            onSkip = onVerifiedExistingUser,
        )
        return
    }

    OnbScaffold(showBack = true, onBack = onBack) {
        Spacer(Modifier.height(24.dp))
        Text("Verify your number", style = VoiidFont.rounded(22, FontWeight.Bold),
            color = VoiidColor.textPrimary, modifier = Modifier.padding(horizontal = 24.dp))

        // Recipient line with an explicit way back to correct a wrong number — a wrong
        // number is the most likely reason the code never arrives. Mirrors iOS `recipient`.
        Row(
            modifier = Modifier.padding(horizontal = 24.dp).padding(top = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(phoneNumber, style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Text(
                "Change",
                style = VoiidFont.rounded(15, FontWeight.Medium),
                color = VoiidColor.primary,
                modifier = Modifier.clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    enabled = !resending && !verifying,
                ) { haptics.tap(); onBack() },
            )
        }
        Text("We sent a $length-digit code to you", style = VoiidFont.rounded(14),
            color = VoiidColor.textSecondary, modifier = Modifier.padding(horizontal = 24.dp).padding(top = 4.dp))

        // Hidden field captures all input; decorationBox renders the display circles.
        BasicTextField(
            value = code,
            onValueChange = { newVal ->
                val digits = newVal.filter(Char::isDigit).take(length)
                if (digits != code) {
                    code = digits
                    // A typed digit that did not complete the code still deserves feedback;
                    // completing it dismisses the keyboard with a soft press. Mirrors iOS.
                    if (digits.isNotEmpty() && digits.length < length) haptics.selection()
                    if (digits.length == length) { focus.clearFocus(); haptics.soft() }
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
                // ONE-TIME-CODE semantics: the Android counterpart of iOS's
                // `.textContentType(.oneTimeCode)` — password managers and Gboard offer the
                // SMS code straight into this field.
                .semantics { contentType = ContentType.Companion.SmsOtpCode }
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

        // Start the expiry clock for the code that was sent on the previous screen.
        androidx.compose.runtime.LaunchedEffect(Unit) { startCountdown() }

        errorText?.let {
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                modifier = Modifier.padding(horizontal = 24.dp).padding(top = 12.dp))
        }

        // Live countdown for the current code — real deadline, one tick per second.
        if (deadlineAt != 0L) {
            val expired = remainingSeconds <= 0
            Text(
                buildAnnotatedString {
                    if (expired) {
                        withStyle(SpanStyle(color = VoiidColor.error)) {
                            append("The code has expired. Request a new one.")
                        }
                    } else {
                        withStyle(SpanStyle(color = VoiidColor.textSecondary)) {
                            append("The code will expire in ")
                        }
                        val total = remainingSeconds.coerceAtLeast(0)
                        withStyle(SpanStyle(color = VoiidColor.primary, fontFeatureSettings = "tnum")) {
                            append("%02d:%02d".format(total / 60, total % 60))
                        }
                    }
                },
                style = VoiidFont.rounded(14),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 16.dp),
            )
        }

        // Resend asks Firebase for a fresh code and REPLACES the verification id.
        Row(
            modifier = Modifier.padding(horizontal = 24.dp).padding(top = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                Icons.Default.Refresh, null,
                tint = VoiidColor.primary, modifier = Modifier.height(18.dp),
            )
            Text("Didn't receive the code?", style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
            Text(
                if (resending) "Sending…" else "Resend code",
                style = VoiidFont.rounded(15, FontWeight.SemiBold),
                color = VoiidColor.primary.copy(alpha = if (resending || verifying) 0.5f else 1f),
                modifier = Modifier
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        enabled = !resending && !verifying,
                    ) { haptics.tap(); resend() },
            )
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

package com.voiid.app.onboarding

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.launch

/**
 * Onboarding — phone entry, built to the brand reference. Twin of iOS
 * `Onboarding/PhoneScreen.swift`; the two must stay identical.
 *
 * The Firebase send is unchanged from the previous version of this screen — only the
 * presentation is new.
 */
@Composable
fun PhoneScreen(
    onBack: () -> Unit,
    onContinue: (phone: String, verificationId: String) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var phone by remember { mutableStateOf("") }
    var country by remember { mutableStateOf(CountryStore.default) }
    var showPicker by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }

    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()

    /** Digits only, so formatting characters a keyboard might insert never reach the wire. */
    val digits = phone.filter { it.isDigit() }

    /**
     * Enough digits to be worth sending. Deliberately loose: national number lengths run from 6
     * to 12, and a client that enforces a per-country length rejects legitimate numbers in
     * places nobody tested. Firebase is the real validator.
     */
    val valid = digits.length >= 6

    // Send the OTP via Firebase, then advance to the OTP screen with the verificationId.
    // (Firebase texts the code; we verify it on the next screen.)
    fun sendOtp() {
        if (sending || !valid) return
        val activity = context as? android.app.Activity ?: run {
            errorText = "Can't start verification"; return
        }
        sending = true; errorText = null
        scope.launch {
            try {
                val e164 = "${country.dialCode}$digits"
                val verificationId = com.voiid.app.net.FirebasePhoneAuth.sendCode(activity, e164)
                haptics.tap(); onContinue(e164, verificationId)
            } catch (e: Exception) {
                errorText = e.message ?: "Couldn't send code"
            }
            sending = false
        }
    }

    Box(Modifier.fillMaxSize().background(OnboardingBrand.ground)) {
        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(4.dp))
            // No help destination exists on this screen yet, so the slot is left empty rather
            // than wired to a no-op that looks broken when tapped.
            OnboardingTopBar(onBack = onBack)

            OnboardingBrandHeader(appeared = appeared)

            // The WORDMARK sits under the mark on this screen, which the first two do not have —
            // the design gives phone entry the full lockup.
            LogoMark(size = 130.dp)

            Spacer(Modifier.height(6.dp))
            OnboardingTitle(leading = "Enter your ", accented = "phone number")
            Spacer(Modifier.height(8.dp))
            Text(
                "We will send you a verification code\nto confirm your number.",
                style = VoiidFont.rounded(17),
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(26.dp))

            // Dial code and number in ONE pill, split by a hairline. One field rather than two:
            // they are one value, and two separate pills invite the user to type the country
            // code into the number half — which then fails validation for a reason the screen
            // never explains.
            val borderColor by animateColorAsState(
                if (focused) OnboardingBrand.lime.copy(alpha = 0.7f)
                else Color.White.copy(alpha = 0.08f),
                tween(180), label = "phoneFieldBorder",
            )
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp)
                    .height(72.dp)
                    .clip(RoundedCornerShape(18.dp))
                    .background(OnboardingBrand.card)
                    .border(if (focused) 1.5.dp else 1.dp, borderColor, RoundedCornerShape(18.dp)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    Modifier
                        .padding(start = 8.dp)
                        .height(56.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(Color.White.copy(alpha = 0.04f))
                        .softClickable { haptics.tap(); showPicker = true }
                        .padding(horizontal = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(country.flag, fontSize = 22.sp)
                    Text(country.dialCode, style = VoiidFont.rounded(17, FontWeight.SemiBold),
                         color = VoiidColor.textPrimary)
                    Icon(Icons.Default.KeyboardArrowDown, contentDescription = null,
                         tint = OnboardingBrand.lime, modifier = Modifier.size(18.dp))
                }

                Box(
                    Modifier
                        .padding(horizontal = 12.dp)
                        .width(1.dp)
                        .height(40.dp)
                        .background(OnboardingBrand.hairline),
                )

                BasicTextField(
                    value = phone,
                    onValueChange = { phone = it },
                    singleLine = true,
                    textStyle = TextStyle(
                        color = VoiidColor.textPrimary,
                        fontSize = 17.sp,
                    ),
                    cursorBrush = SolidColor(OnboardingBrand.lime),
                    interactionSource = interaction,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Phone,
                        imeAction = ImeAction.Go,
                    ),
                    keyboardActions = KeyboardActions(onGo = { sendOtp() }),
                    modifier = Modifier.weight(1f).padding(end = 16.dp),
                    decorationBox = { inner ->
                        if (phone.isEmpty()) {
                            Text("Enter phone number", style = VoiidFont.rounded(17),
                                 color = VoiidColor.placeholder)
                        }
                        inner()
                    },
                )
            }

            errorText?.let {
                Spacer(Modifier.height(10.dp))
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                     textAlign = TextAlign.Center,
                     modifier = Modifier.padding(horizontal = 24.dp))
            }

            Spacer(Modifier.height(20.dp))

            Row(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(Icons.Outlined.VerifiedUser, contentDescription = null,
                     tint = OnboardingBrand.lime, modifier = Modifier.size(24.dp))
                Column {
                    Text("Your number is safe with us",
                         style = VoiidFont.rounded(16, FontWeight.SemiBold),
                         color = VoiidColor.textPrimary)
                    Text("We never share your number with anyone.",
                         style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                }
            }

            Spacer(Modifier.height(18.dp))

            OnboardingTrustStrip(
                items = listOf(
                    TrustItem("e2ee", Icons.Outlined.Lock, "End-to-end", "encrypted"),
                    TrustItem("private", Icons.Outlined.Shield, "Private &", "secure"),
                    TrustItem("nospam", Icons.Outlined.People, "No spam", "promises"),
                    TrustItem("control", Icons.Outlined.CheckCircle, "You're in", "control"),
                ),
                modifier = Modifier.padding(horizontal = 20.dp),
            )

            Spacer(Modifier.weight(1f))

            Box(Modifier.padding(horizontal = 20.dp).fillMaxWidth()) {
                OnboardingPrimaryButton(
                    title = "Continue",
                    busy = sending,
                    // Dimmed while the number is too short to send.
                    modifier = if (valid) Modifier else Modifier.alpha(0.45f),
                ) { sendOtp() }
            }

            Spacer(Modifier.height(14.dp))

            // Consent was already given on the welcome screen; this is a reminder, not a second
            // gate. Kept as plain text because the documents are one step back in the flow and
            // a link here would take the user out of a form they are mid-way through.
            Text(
                buildAnnotatedString {
                    withStyle(SpanStyle(color = VoiidColor.textSecondary)) {
                        append("By continuing, you agree to Voiid's ")
                    }
                    withStyle(SpanStyle(color = OnboardingBrand.lime)) { append("Terms of Service") }
                    withStyle(SpanStyle(color = VoiidColor.textSecondary)) {
                        append(" and acknowledge our ")
                    }
                    withStyle(SpanStyle(color = OnboardingBrand.lime)) { append("Privacy Policy") }
                    withStyle(SpanStyle(color = VoiidColor.textSecondary)) { append(".") }
                },
                style = VoiidFont.rounded(13),
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 24.dp),
            )
            Spacer(Modifier.height(10.dp))
        }
    }

    if (showPicker) {
        CountryPickerSheet(
            selected = country,
            onSelect = { country = it },
            onDismiss = { showPicker = false },
        )
    }
}

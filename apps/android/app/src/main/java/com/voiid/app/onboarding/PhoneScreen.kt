package com.voiid.app.onboarding

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import kotlinx.coroutines.delay
import androidx.compose.ui.platform.LocalFocusManager
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.PersonOutline
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
 * Strip what autofill adds. Port of iOS `PhoneScreen.normalise`.
 *
 * THE GUARD IS THE LENGTH CHECK. A bare national number that happens to start with its own
 * dial digits — a Delhi landline starting "91…" — is only stripped when what remains is still
 * a plausible length, so a legitimate number is never mangled.
 *
 * Android had none of this: autofill returning "+91 98765 43210" was filtered to
 * "919876543210" and then prefixed with the dial code again, sending +91919876543210 — a
 * wrong number that looks correctly entered.
 */
internal fun normalisePhone(raw: String, country: Country): String {
    var d = raw.filter { it.isDigit() }
    val code = country.dialCode.removePrefix("+")

    if (d.length > country.maxDigits && d.startsWith(code)) {
        val stripped = d.removePrefix(code)
        if (stripped.length >= country.minDigits) d = stripped
    }

    // Some regions autofill a trunk "0" prefix ("098765..."). Same guard.
    if (d.length > country.maxDigits && d.startsWith("0")) {
        val stripped = d.removePrefix("0")
        if (stripped.length >= country.minDigits) d = stripped
    }

    return d.take(country.maxDigits)
}



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

    val focus = LocalFocusManager.current
    val fieldFocus = remember { FocusRequester() }
    // 350ms, matching iOS. The field must be attached before focus is requested, and a
    // keyboard that appears before the screen has settled reads as a jump.
    LaunchedEffect(Unit) {
        delay(350)
        runCatching { fieldFocus.requestFocus() }
    }

    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()

    /**
     * Digits only, normalised. Formatting characters a keyboard might insert never reach the
     * wire, and a pasted or autofilled number is stripped of its dial code and trunk zero.
     */
    val digits = normalisePhone(phone, country)

    /**
     * Plausible LENGTH for this country, not a validity check — several countries have
     * genuinely variable formats, and the SMS is the real validator.
     *
     * This was `digits.length >= 6` under a comment arguing that per-country lengths reject
     * legitimate numbers. iOS ships a 237-entry table doing exactly that, so the loose rule
     * was not a shared decision: it let a 6-digit Indian number through to Firebase and put
     * no ceiling on the other end at all.
     */
    val valid = digits.length >= country.minDigits && digits.length <= country.maxDigits

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
                haptics.error()
            }
            sending = false
        }
    }

    Column(Modifier.fillMaxSize().background(VoiidBrand.ground).statusBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            androidx.compose.material3.IconButton(onClick = { focus.clearFocus(); haptics.tap(); onBack() }) {
                Icon(androidx.compose.material.icons.Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                    contentDescription = "Back", tint = VoiidBrand.text, modifier = Modifier.size(28.dp))
            }
        }
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally) {
            OnboardingHeader(
                title = OnboardingTitleSpec.Stacked("Enter your", "phone number"),
                blurb = "We'll send you a verification code\nto confirm your number.",
            )
            Spacer(Modifier.height(24.dp))
            val borderColor by animateColorAsState(
                if (focused) VoiidBrand.lime
                else VoiidBrand.fieldEdge,
                tween(180), label = "phoneFieldBorder",
            )
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(62.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(VoiidBrand.field)
                    .border(if (focused) 1.5.dp else 1.dp, borderColor, RoundedCornerShape(16.dp)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    Modifier
                        .height(62.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .softClickable { haptics.tap(); focus.clearFocus(); showPicker = true }
                        .padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(country.flag, fontSize = 22.sp)
                    Text(country.dialCode, style = VoiidFont.rounded(17, FontWeight.Medium),
                         color = VoiidBrand.text)
                    Icon(Icons.Default.KeyboardArrowDown, contentDescription = null,
                         tint = VoiidBrand.textDim, modifier = Modifier.size(12.dp))
                }

                Box(
                    Modifier
                        .width(1.dp)
                        .height(34.dp)
                        .background(VoiidBrand.hairline),
                )

                BasicTextField(
                    value = phone,
                    onValueChange = { raw ->
                        phone = normalisePhone(raw, country)
                        // Reaching the country's full length is the end of the task: the
                        // keyboard steps out of the way of Continue rather than sitting over
                        // it, and the soft press confirms the number is complete.
                        if (normalisePhone(raw, country).length == country.maxDigits) {
                            focus.clearFocus()
                            haptics.soft()
                        }
                    },
                    singleLine = true,
                    textStyle = VoiidFont.rounded(17, FontWeight.Medium).copy(color = VoiidBrand.text),
                    cursorBrush = SolidColor(VoiidBrand.lime),
                    interactionSource = interaction,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Phone,
                        imeAction = ImeAction.Go,
                    ),
                    keyboardActions = KeyboardActions(onGo = { sendOtp() }),
                    modifier = Modifier.weight(1f).padding(horizontal = 16.dp)
                        .focusRequester(fieldFocus),
                    decorationBox = { inner ->
                        if (phone.isEmpty()) {
                            Text("Phone number", style = VoiidFont.rounded(17, FontWeight.Medium),
                                 color = VoiidBrand.placeholder)
                        }
                        inner()
                    },
                )
            }

            errorText?.let {
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                    textAlign = TextAlign.Center, modifier = Modifier.padding(top = 8.dp))
            }
            Spacer(Modifier.height(24.dp))
            PhonePromiseCard(Icons.Outlined.Lock, "Secure & private", "Your number is encrypted and always private.")
            Spacer(Modifier.height(10.dp))
            PhonePromiseCard(Icons.Outlined.ChatBubbleOutline, "No spam. Ever.", "We never share your number with anyone.")
            Spacer(Modifier.height(10.dp))
            PhonePromiseCard(Icons.Outlined.PersonOutline, "Used only for you", "To verify your identity and keep your account secure.")
            Spacer(Modifier.height(24.dp))
        }
        OnboardingFooter {
            OnboardingKitButton(title = "Continue", enabled = valid && !sending, busy = sending, usesBrandGradient = true) {
                focus.clearFocus()
                sendOtp()
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Lock, null, tint = VoiidBrand.lime, modifier = Modifier.size(13.dp))
                Spacer(Modifier.width(8.dp))
                Text("We'll send a verification code by SMS.\nMessage and data rates may apply.",
                    style = VoiidFont.rounded(12.5f), color = VoiidBrand.textDim, textAlign = TextAlign.Center)
            }
        }
    }

    if (showPicker) {
        CountryPickerSheet(
            selected = country,
            onSelect = { picked ->
                // ONLY when it actually changed. A number typed for India is not a number
                // for Germany, so it is cleared rather than silently re-prefixed — and the
                // field takes focus back so the user can start typing immediately.
                val changed = picked.id != country.id
                country = picked
                if (changed) {
                    phone = ""
                    scope.launch { delay(50); runCatching { fieldFocus.requestFocus() } }
                }
            },
            onDismiss = { showPicker = false },
        )
    }
}

@Composable
private fun PhonePromiseCard(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, detail: String) {
    val shape = RoundedCornerShape(16.dp)
    Row(Modifier.fillMaxWidth().background(VoiidBrand.card, shape).border(1.dp, VoiidBrand.hairline, shape)
        .padding(horizontal = 16.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(46.dp).background(VoiidBrand.lime.copy(alpha = 0.1f), androidx.compose.foundation.shape.CircleShape),
            contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = VoiidBrand.lime, modifier = Modifier.size(19.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidBrand.text)
            Text(detail, style = VoiidFont.rounded(12.5f), color = VoiidBrand.textDim)
        }
        Box(Modifier.width(1.dp).height(40.dp).background(VoiidBrand.hairline))
        Icon(Icons.Outlined.VerifiedUser, null, tint = VoiidBrand.lime, modifier = Modifier.size(20.dp))
    }
}

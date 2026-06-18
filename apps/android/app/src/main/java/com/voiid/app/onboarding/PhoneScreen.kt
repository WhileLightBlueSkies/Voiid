package com.voiid.app.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/** Onboarding — phone number entry (Figma Screen-2). Port of `PhoneScreen.swift`. */
@Composable
fun PhoneScreen(onBack: () -> Unit, onContinue: (phone: String, verificationId: String) -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var phone by remember { mutableStateOf("") }
    var country by remember { mutableStateOf(CountryStore.default) }
    var showPicker by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    val pillShape = RoundedCornerShape(VoiidRadius.pill)

    // Send the OTP via Firebase, then advance to the OTP screen with the
    // verificationId. (Firebase texts the code; we verify it on the next screen.)
    fun sendOtp() {
        if (sending) return
        val activity = context as? android.app.Activity ?: run {
            errorText = "Can’t start verification"; return
        }
        sending = true; errorText = null
        scope.launch {
            try {
                val e164 = "${country.dialCode}$phone"
                val verificationId = com.voiid.app.net.FirebasePhoneAuth.sendCode(activity, e164)
                haptics.tap(); onContinue(e164, verificationId)
            } catch (e: Exception) {
                errorText = e.message ?: "Couldn’t send code"
            }
            sending = false
        }
    }

    OnbScaffold(showBack = true, onBack = onBack) {
        Spacer(Modifier.height(24.dp))

        Text("Your phone number", style = VoiidFont.rounded(22, FontWeight.Bold),
            color = VoiidColor.textPrimary, modifier = Modifier.padding(horizontal = 24.dp))
        Text("Voiid will send a one-time code via SMS\nto verify your number",
            style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 0.dp).padding(top = 6.dp))

        // Country selector — opens a searchable bottom sheet.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(top = 32.dp)
                .height(PILL_HEIGHT)
                .clip(pillShape)
                .background(VoiidColor.fieldFill)
                .border(1.dp, VoiidColor.fieldBorder, pillShape)
                .softClickable(scale = 0.985f) { haptics.tap(); showPicker = true }
                .padding(horizontal = 24.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(country.flag, fontSize = 22.sp)
            Text(country.name, style = VoiidFont.rounded(17), color = VoiidColor.adaptiveText)
            Spacer(Modifier.weight(1f))
            Icon(Icons.Default.KeyboardArrowDown, null,
                tint = VoiidColor.adaptiveText.copy(alpha = 0.6f), modifier = Modifier.width(18.dp))
        }

        // Dial-code pill + number pill
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .width(84.dp)
                    .height(PILL_HEIGHT)
                    .clip(pillShape)
                    .background(VoiidColor.fieldFill)
                    .border(1.dp, VoiidColor.fieldBorder, pillShape),
                contentAlignment = Alignment.Center,
            ) {
                Text(country.dialCode, style = VoiidFont.rounded(17), color = VoiidColor.adaptiveText)
            }
            OnbPillField(
                placeholder = "91234567890",
                value = phone,
                onValueChange = { phone = it.filter(Char::isDigit) },
                keyboardType = KeyboardType.Number,
                modifier = Modifier.weight(1f),
            )
        }

        Spacer(Modifier.weight(1f))

        errorText?.let {
            Text(it, style = VoiidFont.rounded(12), color = VoiidColor.error,
                modifier = Modifier.padding(horizontal = 24.dp).padding(top = 6.dp))
        }

        OnbAccentButton(
            title = if (sending) "Sending…" else "Continue",
            enabled = phone.length >= 10 && !sending,
            modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp),
        ) { sendOtp() }
    }

    if (showPicker) {
        CountryPickerSheet(
            selected = country,
            onSelect = { country = it },
            onDismiss = { showPicker = false },
        )
    }
}

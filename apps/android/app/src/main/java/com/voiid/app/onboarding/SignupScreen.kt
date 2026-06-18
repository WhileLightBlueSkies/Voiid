package com.voiid.app.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
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
import com.voiid.app.model.AppSession
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/** Onboarding — full name + email (Figma Screen-4). Port of `SignupScreen.swift`. */
@Composable
fun SignupScreen(session: AppSession, phone: String = "", onBack: () -> Unit, onContinue: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    var name by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    val emailRegex = remember { Regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$") }
    val valid = name.trim().isNotEmpty() && emailRegex.matches(email.trim())
    val pillShape = RoundedCornerShape(VoiidRadius.pill)

    OnbScaffold(showBack = true, onBack = onBack) {
        Spacer(Modifier.height(40.dp))
        Text("Let's get started", style = VoiidFont.rounded(34, FontWeight.Bold),
            color = VoiidColor.textPrimary, modifier = Modifier.padding(horizontal = 24.dp, vertical = 0.dp).padding(bottom = 8.dp))

        OnbPillField("Full name", name, { name = it }, Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 16.dp))
        OnbPillField("Email Address", email, { email = it },
            Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 16.dp), keyboardType = KeyboardType.Email)

        // Verified phone — grey-filled, read-only, with green check
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(top = 16.dp)
                .height(PILL_HEIGHT)
                .clip(pillShape)
                .background(VoiidColor.bubbleSent)
                .padding(horizontal = 24.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(phone.ifEmpty { "Verified number" }, style = VoiidFont.rounded(17), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Icon(Icons.Default.CheckCircle, "Verified", tint = VoiidColor.success, modifier = Modifier.width(24.dp))
        }

        Spacer(Modifier.weight(1f))

        OnbAccentButton(
            title = "Continue",
            enabled = valid,
            modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp),
        ) {
            session.profile = session.profile.copy(fullName = name)
            haptics.tap(); onContinue()
        }
    }
}

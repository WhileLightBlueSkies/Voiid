package com.voiid.app.onboarding

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PhotoCamera
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.voiid.app.model.AppSession
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidWordmark
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/** Onboarding — profile photo + about (Figma Screen-5). Port of `CreateProfileScreen.swift`. */
@Composable
fun CreateProfileScreen(session: AppSession, onBack: () -> Unit, onFinish: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    var about by remember { mutableStateOf("") }
    var photoUri by remember { mutableStateOf<Uri?>(null) }
    val avatar = 110.dp

    val pickMedia = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) { photoUri = uri; haptics.success() }
    }

    OnbScaffold(showBack = true, onBack = onBack) {
        Spacer(Modifier.height(8.dp))
        Text("Create profile", style = VoiidFont.rounded(22, FontWeight.Bold),
            color = VoiidColor.textPrimary, modifier = Modifier.padding(horizontal = 24.dp))

        // Avatar with pink camera badge (centered)
        Box(Modifier.fillMaxWidth().padding(top = 32.dp), contentAlignment = Alignment.Center) {
            Box(contentAlignment = Alignment.BottomEnd) {
                Box(
                    modifier = Modifier.size(avatar).clip(CircleShape).background(VoiidColor.fieldFill)
                        .clickable { pickMedia.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                    contentAlignment = Alignment.Center,
                ) {
                    if (photoUri != null) {
                        AsyncImage(
                            model = photoUri,
                            contentDescription = "Profile photo",
                            modifier = Modifier.size(avatar).clip(CircleShape),
                            contentScale = ContentScale.Crop,
                        )
                    } else {
                        VoiidWordmark(fontSize = 26, alpha = 0.25f)
                    }
                }
                // Pink camera badge
                Box(
                    modifier = Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.accent)
                        .border(2.dp, VoiidColor.background, CircleShape)
                        .clickable { pickMedia.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Default.PhotoCamera, "Pick photo", tint = VoiidColor.primary, modifier = Modifier.size(16.dp))
                }
            }
        }

        // About you text area
        val aboutShape = RoundedCornerShape(28.dp)
        BasicTextField(
            value = about,
            onValueChange = { about = it },
            textStyle = VoiidFont.rounded(17).merge(TextStyle(color = VoiidColor.textPrimary)),
            cursorBrush = SolidColor(VoiidColor.primary),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(top = 48.dp)
                .heightIn(min = 130.dp)
                .clip(aboutShape)
                .background(VoiidColor.fieldFill)
                .border(1.dp, VoiidColor.fieldBorder, aboutShape)
                .padding(horizontal = 24.dp, vertical = 16.dp),
            maxLines = 7,
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.TopStart) {
                    if (about.isEmpty()) Text("About you", style = VoiidFont.rounded(17), color = VoiidColor.placeholder)
                    inner()
                }
            },
        )

        Spacer(Modifier.weight(1f))

        OnbAccentButton(
            title = "Sign up",
            enabled = true,
            modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp),
        ) {
            session.profile = session.profile.copy(bio = about)
            haptics.success(); onFinish()
        }
    }
}

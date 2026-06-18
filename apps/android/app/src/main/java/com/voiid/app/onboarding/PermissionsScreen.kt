package com.voiid.app.onboarding

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Contacts
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * Upfront permissions (spec: requested at first launch, before login). Asks for
 * contacts, camera, mic, photos/media and notifications in one native prompt.
 * Best-effort: the user may deny any; we continue regardless and re-ask in-context
 * later where a feature needs it.
 */
@Composable
fun PermissionsScreen(onContinue: () -> Unit) {
    val haptics = LocalVoiidHaptics.current

    val permissions = buildList {
        add(Manifest.permission.READ_CONTACTS)
        add(Manifest.permission.CAMERA)
        add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.READ_MEDIA_IMAGES)
            add(Manifest.permission.READ_MEDIA_VIDEO)
            add(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            @Suppress("DEPRECATION")
            add(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }.toTypedArray()

    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { _ -> haptics.success(); onContinue() }   // continue whatever the user chose

    OnbScaffold(showBack = false, onBack = {}) {
        Spacer(Modifier.height(48.dp))
        Text("Enable permissions", style = VoiidFont.rounded(28, FontWeight.Bold),
            color = VoiidColor.textPrimary, modifier = Modifier.padding(horizontal = 24.dp))
        Text("Voiid needs a few permissions to work. You're always in control.",
            style = VoiidFont.rounded(15), color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 24.dp).padding(top = 6.dp, bottom = 8.dp))

        Spacer(Modifier.height(16.dp))
        Row1(Icons.Default.Contacts, "Contacts", "Find friends already on Voiid (matched on-device, never uploaded).")
        Row1(Icons.Default.CameraAlt, "Camera", "Take photos and videos for chats and clips.")
        Row1(Icons.Default.Mic, "Microphone", "Record voice messages and clips.")
        Row1(Icons.Default.PhotoLibrary, "Photos & media", "Share images and videos.")
        Row1(Icons.Default.Notifications, "Notifications", "Get notified about new messages and calls.")

        Spacer(Modifier.weight(1f))

        OnbAccentButton(
            title = "Allow access",
            enabled = true,
            modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 12.dp),
        ) { haptics.tap(); launcher.launch(permissions) }

        Text("You can change these later in Settings.",
            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
            modifier = Modifier.fillMaxWidth().padding(bottom = 24.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

@Composable
private fun Row1(icon: ImageVector, title: String, desc: String) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(26.dp))
        Column {
            Text(title, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Text(desc, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        }
    }
}

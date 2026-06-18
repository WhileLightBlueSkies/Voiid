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
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import kotlinx.coroutines.launch
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
import com.voiid.app.net.ProfileService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidWordmark
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/** Username availability state (Clips handle). */
private sealed interface UStatus {
    data object Idle : UStatus
    data object Checking : UStatus
    data object Available : UStatus
    data class Taken(val reason: String) : UStatus
}

/** Onboarding — profile photo + about (Figma Screen-5). Port of `CreateProfileScreen.swift`. */
@Composable
fun CreateProfileScreen(session: AppSession, onBack: () -> Unit, onFinish: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val profileService = remember { ProfileService(context) }

    var username by remember { mutableStateOf("") }
    var about by remember { mutableStateOf("") }
    var photoUri by remember { mutableStateOf<Uri?>(null) }
    var uStatus by remember { mutableStateOf<UStatus>(UStatus.Idle) }
    var saving by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    val avatar = 110.dp

    // Name was already collected on the Signup screen (session.profile.fullName).
    val canSubmit = session.profile.fullName.isNotBlank() && uStatus is UStatus.Available && !saving

    // Debounced availability check whenever the (normalized) username changes.
    androidx.compose.runtime.LaunchedEffect(username) {
        if (username.length < 3) { uStatus = UStatus.Idle; return@LaunchedEffect }
        uStatus = UStatus.Checking
        kotlinx.coroutines.delay(400)   // debounce
        uStatus = try {
            val r = profileService.checkUsername(username)
            if (r.available) UStatus.Available else UStatus.Taken(r.reason ?: "Username taken")
        } catch (e: Exception) {
            UStatus.Taken("Couldn’t check — try again")
        }
    }

    fun submit() {
        if (!canSubmit) return
        saving = true; errorText = null
        scope.launch {
            try {
                profileService.updateProfile(
                    fullName = session.profile.fullName.trim(),
                    bio = about.ifBlank { null },
                    username = username,
                )
                session.profile = session.profile.copy(bio = about)
                haptics.success(); onFinish()
            } catch (e: com.voiid.app.net.ApiError.Http) {
                if (e.status == 409) { uStatus = UStatus.Taken("Just taken — pick another"); errorText = "That username was just taken." }
                else errorText = e.message
                haptics.tap()
            } catch (e: Exception) {
                errorText = e.message ?: "Couldn’t save profile."; haptics.tap()
            }
            saving = false
        }
    }

    // iOS fires NO haptic on photo selection (only success() on Sign-up). Match that.
    val pickMedia = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) photoUri = uri
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
                        // iOS shows the wordmark mark at ~half the avatar width (≈55pt),
                        // opacity 0.25. Size the Android wordmark up to read the same.
                        VoiidWordmark(fontSize = 34, alpha = 0.25f)
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
                    Icon(Icons.Default.PhotoCamera, "Pick photo", tint = VoiidColor.primary, modifier = Modifier.size(14.dp))
                }
            }
        }

        // Username field (Clips handle) + live availability
        // (Name was collected on the previous Signup screen.)
        val fieldShape = RoundedCornerShape(com.voiid.app.ui.theme.VoiidRadius.pill)
        val uBorder = when (uStatus) {
            is UStatus.Available -> VoiidColor.success
            is UStatus.Taken -> VoiidColor.error
            else -> VoiidColor.fieldBorder
        }
        androidx.compose.foundation.layout.Column(Modifier.padding(horizontal = 24.dp).padding(top = 32.dp)) {
            androidx.compose.foundation.layout.Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().height(61.dp).clip(fieldShape)
                    .background(VoiidColor.fieldFill).border(1.dp, uBorder, fieldShape)
                    .padding(horizontal = 16.dp),
            ) {
                Text("@", style = VoiidFont.rounded(17), color = VoiidColor.placeholder)
                Spacer(Modifier.size(6.dp))
                BasicTextField(
                    value = username,
                    onValueChange = { raw -> username = raw.lowercase().filter { it.isLetterOrDigit() || it == '_' } },
                    singleLine = true,
                    textStyle = VoiidFont.rounded(17).merge(TextStyle(color = VoiidColor.textPrimary)),
                    cursorBrush = SolidColor(VoiidColor.primary),
                    modifier = Modifier.weight(1f),
                    decorationBox = { inner ->
                        Box(contentAlignment = Alignment.CenterStart) {
                            if (username.isEmpty()) Text("username", style = VoiidFont.rounded(17), color = VoiidColor.placeholder)
                            inner()
                        }
                    },
                )
                when (uStatus) {
                    is UStatus.Checking -> androidx.compose.material3.CircularProgressIndicator(
                        modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = VoiidColor.textSecondary)
                    is UStatus.Available -> Icon(Icons.Default.CheckCircle, null, tint = VoiidColor.success, modifier = Modifier.size(20.dp))
                    is UStatus.Taken -> Icon(Icons.Default.Cancel, null, tint = VoiidColor.error, modifier = Modifier.size(20.dp))
                    else -> {}
                }
            }
            val hint = (uStatus as? UStatus.Taken)?.reason ?: "Used only in Clips. Letters, digits, underscore."
            val hintColor = if (uStatus is UStatus.Taken) VoiidColor.error else VoiidColor.textSecondary
            Text(hint, style = VoiidFont.rounded(12), color = hintColor, modifier = Modifier.padding(top = 4.dp))
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
                .padding(top = 16.dp)
                .heightIn(min = 96.dp)
                .clip(aboutShape)
                .background(VoiidColor.fieldFill)
                .border(1.dp, VoiidColor.fieldBorder, aboutShape)
                .padding(horizontal = 24.dp, vertical = 16.dp),
            maxLines = 6,
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.TopStart) {
                    if (about.isEmpty()) Text("About you", style = VoiidFont.rounded(17), color = VoiidColor.placeholder)
                    inner()
                }
            },
        )

        errorText?.let {
            Text(it, style = VoiidFont.rounded(12), color = VoiidColor.error,
                modifier = Modifier.padding(horizontal = 24.dp).padding(top = 6.dp))
        }

        Spacer(Modifier.weight(1f))

        OnbAccentButton(
            title = if (saving) "Signing up…" else "Sign up",
            enabled = canSubmit,
            modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp),
        ) { submit() }
    }
}

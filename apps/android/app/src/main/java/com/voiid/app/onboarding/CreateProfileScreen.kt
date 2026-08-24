package com.voiid.app.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.outlined.GppGood
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.main.MediaCache
import com.voiid.app.model.AppSession
import com.voiid.app.net.MediaService
import com.voiid.app.net.ProfileService
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * Onboarding OPTIONAL details — email + bio, port of iOS `CreateProfileScreen`.
 *
 * Everything REQUIRED was collected on the previous screen; both fields here are optional and
 * "Skip for now" saves the SAME required fields while declining only these extras. It is not a
 * way out of creating the profile, and must not look like one.
 *
 * This is also THE SINGLE SERVER WRITE for the whole flow: name, username, photo (if chosen),
 * then email/bio when provided.
 */
@Composable
fun CreateProfileScreen(
    session: AppSession,
    draft: SignupDraft,
    onBack: () -> Unit,
    onFinish: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    var email by remember { mutableStateOf("") }
    var bio by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    // Empty is fine. A typed value has to LOOK like an address — deliberately loose, because
    // strict matching rejects valid addresses and the real test is a confirmation mail. iOS.
    val emailValid = email.trim().isEmpty() || run {
        val parts = email.trim().split("@")
        parts.size == 2 && parts[0].isNotEmpty() && parts[1].contains(".") &&
            !parts[1].startsWith(".") && !parts[1].endsWith(".")
    }
    val canFinish = emailValid && !saving

    fun submit(includeExtras: Boolean) {
        if (saving) return
        saving = true
        errorText = null
        scope.launch {
            try {
                // Photo first, so the profile write can reference its key.
                var photoKey: String? = null
                draft.photoJpeg?.let { bytes ->
                    photoKey = MediaService(TokenStore.get(context)).uploadProfilePhoto(bytes)
                    // Local-first: cache under the key so the avatar shows instantly everywhere.
                    MediaCache.putData(context, photoKey!!, bytes)
                }
                ProfileService(context).updateProfile(
                    fullName = draft.fullName,
                    username = draft.username,
                    photoUrl = photoKey,
                    email = if (includeExtras && email.isNotBlank()) email.trim() else null,
                    bio = if (includeExtras && bio.isNotBlank()) bio.trim() else null,
                )
                session.profile = session.profile.copy(
                    fullName = draft.fullName,
                    username = draft.username,
                    email = if (includeExtras) email.trim() else session.profile.email,
                    bio = if (includeExtras) bio.trim() else session.profile.bio,
                    photoURL = photoKey ?: session.profile.photoURL,
                )
                haptics.success()
                onFinish()
            } catch (e: com.voiid.app.net.ApiError.Http) {
                if (e.status == 409) {
                    // The name was free a moment ago and was taken in between. Sending the user
                    // back is the only honest fix — the field that has to change is on the other
                    // page. Mirrors iOS.
                    errorText = "That username was just taken. Go back and choose another."
                } else {
                    errorText = e.message ?: "Couldn't save profile."
                }
                haptics.error()
            } catch (e: Exception) {
                errorText = e.message ?: "Couldn't save profile."
                haptics.error()
            }
            saving = false
        }
    }

    OnbScaffold(showBack = true, onBack = onBack) {
        Spacer(Modifier.height(16.dp))
        Text("A few more details", style = VoiidFont.rounded(28, FontWeight.Bold),
            color = VoiidColor.textPrimary, modifier = Modifier.padding(horizontal = 24.dp))
        Text("Both are optional — you can add them later.", style = VoiidFont.rounded(15),
            color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 24.dp).padding(top = 6.dp))

        EmailField(
            email = email,
            valid = emailValid,
            onChange = { email = it },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 28.dp),
        )
        Text("Used to help you recover your account.",
            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 28.dp).padding(top = 4.dp))

        BioField(
            bio = bio,
            onChange = { if (it.length <= 120) bio = it },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 16.dp),
        )
        Text("${bio.length}/120", style = VoiidFont.rounded(12),
            color = VoiidColor.textSecondary.copy(alpha = 0.8f),
            modifier = Modifier.padding(horizontal = 28.dp).padding(top = 4.dp))

        errorText?.let {
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                modifier = Modifier.padding(horizontal = 24.dp).padding(top = 10.dp))
        }

        PrivacyNote(modifier = Modifier.padding(horizontal = 24.dp).padding(top = 20.dp))

        Spacer(Modifier.weight(1f))

        OnbAccentButton(
            title = if (saving) "Saving…" else "Finish",
            enabled = canFinish,
            modifier = Modifier.padding(horizontal = 24.dp),
        ) { submit(includeExtras = true) }
        Spacer(Modifier.height(10.dp))
        Text(
            "Skip for now",
            style = VoiidFont.rounded(15),
            color = VoiidColor.textSecondary.copy(alpha = if (saving) 0.5f else 1f),
            modifier = Modifier
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    enabled = !saving,
                ) {
                    haptics.tap()
                    submit(includeExtras = false)
                },
        )
        Spacer(Modifier.height(32.dp))
    }
}

@Composable
private fun EmailField(email: String, valid: Boolean, onChange: (String) -> Unit, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(com.voiid.app.ui.theme.VoiidRadius.pill)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .height(PILL_HEIGHT)
            .clip(shape)
            .background(VoiidColor.fieldFill)
            .border(1.dp, if (!valid) VoiidColor.error else VoiidColor.fieldBorder, shape)
            .padding(horizontal = 20.dp),
    ) {
        BasicTextField(
            value = email,
            onValueChange = onChange,
            singleLine = true,
            textStyle = VoiidFont.rounded(17).merge(TextStyle(color = VoiidColor.textPrimary)),
            cursorBrush = SolidColor(VoiidColor.primary),
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                keyboardType = androidx.compose.ui.text.input.KeyboardType.Email,
            ),
            modifier = Modifier.weight(1f),
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (email.isEmpty()) {
                        Text("Email address", style = VoiidFont.rounded(17),
                             color = VoiidColor.placeholder)
                    }
                    inner()
                }
            },
        )
        if (email.isNotEmpty() && !valid) {
            Icon(Icons.Default.Cancel, null, tint = VoiidColor.error, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun BioField(bio: String, onChange: (String) -> Unit, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(28.dp)
    BasicTextField(
        value = bio,
        onValueChange = onChange,
        textStyle = VoiidFont.rounded(17).merge(TextStyle(color = VoiidColor.textPrimary)),
        cursorBrush = SolidColor(VoiidColor.primary),
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 96.dp)
            .clip(shape)
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.fieldBorder, shape)
            .padding(horizontal = 24.dp, vertical = 16.dp),
        maxLines = 6,
        decorationBox = { inner ->
            Box(contentAlignment = Alignment.TopStart) {
                if (bio.isEmpty()) {
                    Text("Tell the world about yourself", style = VoiidFont.rounded(17),
                         color = VoiidColor.placeholder)
                }
                inner()
            }
        },
    )
}

/** The one reassurance on the screen: nothing here is public. */
@Composable
private fun PrivacyNote(modifier: Modifier = Modifier) {
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(16.dp))
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(46.dp).clip(CircleShape)
                .background(VoiidColor.primary.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Outlined.GppGood, null, tint = VoiidColor.primary, modifier = Modifier.size(22.dp))
        }
        Column(Modifier.weight(1f)) {
            Text("You control what you share",
                 style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Text(
                "Your email is never shown to other people, and you can change any of this in Settings.",
                style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

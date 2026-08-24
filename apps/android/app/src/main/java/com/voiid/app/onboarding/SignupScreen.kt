package com.voiid.app.onboarding

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.Image
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.AppSession
import com.voiid.app.net.ProfileService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import java.io.ByteArrayOutputStream

/** Username availability lifecycle, checked against the server as the user types. */
private sealed interface UStatus {
    data object Idle : UStatus
    data object Checking : UStatus
    data object Available : UStatus
    data class Taken(val reason: String) : UStatus
}

/**
 * Onboarding identity step — PHOTO + NAME + USERNAME, port of iOS `SignupScreen`.
 *
 * Field ownership matches iOS: everything REQUIRED about the person is collected here (the
 * verified phone is shown read-only below), and the NEXT screen collects only OPTIONAL extras
 * (email, bio). The single server write happens there, once.
 */
@Composable
fun SignupScreen(
    session: AppSession,
    phone: String = "",
    onBack: () -> Unit,
    onContinue: (SignupDraft) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val context = LocalContext.current
    var name by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var photoJpeg by remember { mutableStateOf<ByteArray?>(null) }
    var photoError by remember { mutableStateOf<String?>(null) }
    var uStatus by remember { mutableStateOf<UStatus>(UStatus.Idle) }

    val nameValid = name.trim().length >= 2
    // FORMAT rules first and locally: 3–20 characters, letters/digits/underscore, no leading
    // digit. Availability is a separate question — see [uStatus]. Mirrors iOS.
    val usernameWellFormed = username.length in 3..20 &&
        username.all { it.isLetterOrDigit() || it == '_' } &&
        !(username.firstOrNull()?.isDigit() == true)
    val canContinue = nameValid && uStatus == UStatus.Available

    // Debounced availability check. An obviously invalid name never costs a round trip.
    LaunchedEffect(username) {
        if (!usernameWellFormed) {
            uStatus = UStatus.Idle
            return@LaunchedEffect
        }
        uStatus = UStatus.Checking
        kotlinx.coroutines.delay(400)   // debounce
        uStatus = try {
            val r = ProfileService(context).checkUsername(username)
            if (r.available) UStatus.Available else UStatus.Taken(r.reason ?: "Username taken")
        } catch (e: Exception) {
            UStatus.Taken("Couldn't check — try again")
        }
    }

    val pickMedia = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) {
            // The limit is enforced HERE, at pick time — a user with a 12MB photo learns now,
            // not after filling in the rest of the form. Mirrors iOS.
            val bytes = loadAndDownscale(context, uri)
            if (bytes != null) {
                photoJpeg = bytes
                photoError = null
                haptics.success()
            } else {
                photoJpeg = null
                photoError = "That photo couldn't be used. PNG, JPG or WEBP up to 5MB."
                haptics.error()
            }
        }
    }

    OnbScaffold(showBack = true, onBack = onBack) {
        Spacer(Modifier.height(16.dp))
        Text("Let's set up your profile", style = VoiidFont.rounded(28, FontWeight.Bold),
            color = VoiidColor.textPrimary, modifier = Modifier.padding(horizontal = 24.dp))
        Text("Add a few details to get started.", style = VoiidFont.rounded(15),
            color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 24.dp).padding(top = 6.dp))

        AvatarPicker(
            photoJpeg = photoJpeg,
            onPick = { pickMedia.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
            modifier = Modifier.padding(top = 24.dp),
        )
        Text(
            if (photoJpeg != null) "Profile photo added" else "Add profile photo",
            style = VoiidFont.rounded(15, FontWeight.SemiBold),
            color = VoiidColor.textPrimary,
            modifier = Modifier.padding(top = 10.dp),
        )
        Text("PNG, JPG or WEBP. Max 5MB.", style = VoiidFont.rounded(12),
            color = VoiidColor.textSecondary, modifier = Modifier.padding(top = 2.dp))
        photoError?.let {
            Text(it, style = VoiidFont.rounded(12), color = VoiidColor.error,
                modifier = Modifier.padding(horizontal = 24.dp).padding(top = 4.dp))
        }

        OnbPillField(
            "Full name", name, { name = it },
            Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 20.dp),
        )

        UsernameField(
            username = username,
            status = uStatus,
            wellFormed = usernameWellFormed,
            onChange = { raw ->
                // Usernames are lowercase and unspaced. Correcting as they type beats
                // rejecting after. Mirrors iOS.
                username = raw.lowercase().filter { it.isLetterOrDigit() || it == '_' }.take(20)
            },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 12.dp),
        )

        VerifiedPhoneRow(phone.ifEmpty { session.profile.phoneNumber })

        Spacer(Modifier.weight(1f))

        OnbAccentButton(
            title = "Continue",
            enabled = canContinue,
            modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp),
        ) {
            // Kept in the session too, so anything reading the live profile before the save
            // lands shows the real name rather than a blank. Mirrors iOS.
            session.updateProfile(fullName = name.trim())
            onContinue(
                SignupDraft(
                    fullName = name.trim(),
                    username = username,
                    photoJpeg = photoJpeg,
                )
            )
        }
    }
}

/** The identity half handed from this step to the next (twin of iOS `ProfileDraft`). */
class SignupDraft(
    val fullName: String = "",
    val username: String = "",
    /** Resized JPEG bytes (≤1024px, ≤5MB) ready for upload. */
    val photoJpeg: ByteArray? = null,
)

// MARK: - Avatar

@Composable
private fun AvatarPicker(photoJpeg: ByteArray?, onPick: () -> Unit, modifier: Modifier = Modifier) {
    val avatar = 84.dp
    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Box(contentAlignment = Alignment.BottomEnd) {
            Box(
                modifier = Modifier
                    .size(avatar)
                    .clip(CircleShape)
                    .background(VoiidColor.fieldFill)
                    .border(1.dp, VoiidColor.fieldBorder, CircleShape)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) { onPick() },
                contentAlignment = Alignment.Center,
            ) {
                val bmp = remember(photoJpeg) {
                    photoJpeg?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
                }
                if (bmp != null) {
                    Image(
                        bitmap = bmp.asImageBitmap(),
                        contentDescription = "Profile photo",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.size(avatar).clip(CircleShape),
                    )
                } else {
                    Icon(Icons.Default.PhotoCamera, null, tint = VoiidColor.primary,
                         modifier = Modifier.size(26.dp))
                }
            }
            // The affordance stays after a photo exists: it then means "change it".
            Box(
                modifier = Modifier
                    .size(30.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.accent)
                    .border(3.dp, VoiidColor.background, CircleShape)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) { onPick() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Default.PhotoCamera, "Pick photo", tint = VoiidColor.primary,
                     modifier = Modifier.size(13.dp))
            }
        }
    }
}

// MARK: - Username

@Composable
private fun UsernameField(
    username: String,
    status: UStatus,
    wellFormed: Boolean,
    onChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(VoiidRadius.pill)
    Column(modifier) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .height(PILL_HEIGHT)
                .clip(shape)
                .background(VoiidColor.fieldFill)
                .border(1.dp, if (status is UStatus.Taken) VoiidColor.error else VoiidColor.fieldBorder, shape)
                .padding(horizontal = 20.dp),
        ) {
            Text("@", style = VoiidFont.rounded(17), color = VoiidColor.placeholder)
            Spacer(Modifier.width(6.dp))
            BasicTextField(
                value = username,
                onValueChange = onChange,
                singleLine = true,
                textStyle = VoiidFont.rounded(17).merge(TextStyle(color = VoiidColor.textPrimary)),
                cursorBrush = SolidColor(VoiidColor.primary),
                modifier = Modifier.weight(1f),
                decorationBox = { inner ->
                    Box(contentAlignment = Alignment.CenterStart) {
                        if (username.isEmpty()) {
                            Text("Choose a unique username", style = VoiidFont.rounded(17),
                                 color = VoiidColor.placeholder)
                        }
                        inner()
                    }
                },
            )
            when (status) {
                is UStatus.Checking -> CircularProgressIndicator(
                    modifier = Modifier.size(18.dp), strokeWidth = 2.dp,
                    color = VoiidColor.textSecondary)
                is UStatus.Available -> Icon(Icons.Default.CheckCircle, null,
                    tint = VoiidColor.success, modifier = Modifier.size(20.dp))
                is UStatus.Taken -> Icon(Icons.Default.Cancel, null,
                    tint = VoiidColor.error, modifier = Modifier.size(20.dp))
                is UStatus.Idle -> {}
            }
        }
        Text(
            usernameHelp(username, status, wellFormed),
            style = VoiidFont.rounded(12),
            color = if (status is UStatus.Taken || (username.isNotEmpty() && !wellFormed)) {
                VoiidColor.error
            } else VoiidColor.textSecondary,
            modifier = Modifier.padding(start = 4.dp, top = 4.dp),
        )
    }
}

/** Says what is actually true at each stage. Mirrors iOS `usernameHelp`. */
private fun usernameHelp(username: String, status: UStatus, wellFormed: Boolean): String {
    if (username.isEmpty()) return "This will be your unique Voiid ID."
    if (username.length < 3) return "At least 3 characters."
    if (username.first().isDigit()) return "Can't start with a number."
    if (!wellFormed) return "Letters, numbers and underscores only."
    return when (status) {
        is UStatus.Checking -> "Checking availability…"
        is UStatus.Available -> "Available."
        is UStatus.Taken -> status.reason
        is UStatus.Idle -> "This will be your unique Voiid ID."
    }
}

// MARK: - Verified number

/// The number is already proven, so it is shown rather than asked for.
@Composable
private fun VerifiedPhoneRow(phone: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp)
            .padding(top = 16.dp)
            .height(PILL_HEIGHT)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(VoiidColor.bubbleSent)
            .padding(horizontal = 24.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text("Verified number", style = VoiidFont.rounded(12),
                 color = VoiidColor.textSecondary)
            Text(phone.ifEmpty { "—" }, style = VoiidFont.rounded(16),
                 color = VoiidColor.textPrimary)
        }
        Icon(Icons.Default.CheckCircle, "Verified", tint = VoiidColor.success,
             modifier = Modifier.width(24.dp))
    }
}

// MARK: - Photo loading

/**
 * Reads the picked image, downscales to a 1024px max dimension, compresses JPEG q0.85, and
 * enforces the stated 5MB limit. Returns null when the result would be unusable.
 */
private fun loadAndDownscale(context: Context, uri: Uri): ByteArray? = runCatching {
    val resolver = context.contentResolver
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        ?: return null
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

    val maxDimension = 1024
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxDimension) sample *= 2
    val opts = BitmapFactory.Options().apply { inSampleSize = sample }
    val decoded = resolver.openInputStream(uri)?.use {
        BitmapFactory.decodeStream(it, null, opts)
    } ?: return null

    val scaled = if (maxOf(decoded.width, decoded.height) > maxDimension) {
        val scale = maxDimension.toFloat() / maxOf(decoded.width, decoded.height)
        Bitmap.createScaledBitmap(
            decoded,
            (decoded.width * scale).toInt().coerceAtLeast(1),
            (decoded.height * scale).toInt().coerceAtLeast(1),
            true,
        )
    } else decoded

    val out = ByteArrayOutputStream()
    scaled.compress(Bitmap.CompressFormat.JPEG, 85, out)
    val bytes = out.toByteArray()
    if (bytes.size > 5 * 1024 * 1024) null else bytes
}.getOrNull()

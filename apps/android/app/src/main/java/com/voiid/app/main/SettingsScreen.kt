package com.voiid.app.main

import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.model.AppSession
import com.voiid.app.net.MediaService
import com.voiid.app.net.ProfileService
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidCircleBack
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Settings, reached by tapping your own avatar at the top-left of the Chats screen — port of
 * iOS `SettingsSheet.swift`. Before this the only way into any of it was a two-item overflow
 * menu, and there was no way at all to set a profile picture.
 *
 * The profile block writes LOCALLY FIRST (session + the local users row) and then syncs, so
 * editing your name offline shows the new name immediately and reconciles when the network
 * returns — the same rule the rest of the app follows.
 */
@Composable
fun SettingsScreen(
    session: AppSession,
    onClose: () -> Unit,
    onBackupRecovery: () -> Unit,
    onPrivacy: () -> Unit,
    onStorage: () -> Unit,
    onLinkedDevices: () -> Unit,
    onAbout: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var editingName by remember { mutableStateOf(false) }
    var draftName by remember { mutableStateOf(session.profile.fullName) }
    var uploading by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    // Photos picker (system UI — no READ_MEDIA_IMAGES permission needed).
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            uploading = true
            errorText = try {
                val bytes = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                }
                if (bytes == null) "Couldn't read that photo." else {
                    val key = MediaService(TokenStore.get(context)).uploadProfilePhoto(bytes)
                    session.updateProfile(photoUrl = key)   // local first
                    ProfileService(context).updateProfile(photoUrl = key)
                    null
                }
            } catch (e: Exception) {
                "Couldn't update your photo. Try again."
            }
            uploading = false
        }
    }

    fun saveName() {
        val name = draftName.trim()
        if (name.isEmpty()) { editingName = false; return }
        // Local first: the new name is on screen (and durable) before the request is even
        // attempted, so this works offline and survives a restart.
        session.updateProfile(fullName = name)
        editingName = false
        scope.launch {
            errorText = runCatching { ProfileService(context).updateProfile(fullName = name) }
                .fold({ null }, { "Saved on this device — will sync when you're back online." })
        }
    }

    Column(
        Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding(),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            VoiidCircleBack(onBack = onClose)
            Spacer(Modifier.width(8.dp))
            Text("Settings", style = VoiidFont.rounded(20, FontWeight.Bold), color = VoiidColor.textPrimary)
        }

        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState())
                .padding(24.dp).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            // ---- profile card
            Column(
                Modifier.fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.surfaceCard)
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Box(contentAlignment = Alignment.BottomEnd) {
                    ProfileAvatar(
                        photoUrl = session.profile.photoURL,
                        name = session.profile.fullName,
                        size = 96.dp,
                        modifier = Modifier.softClickable(scale = 0.95f) {
                            if (!uploading) {
                                haptics.tap()
                                picker.launch(
                                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                )
                            }
                        },
                    )
                    // Affordance: without this it isn't obvious the avatar is tappable.
                    Box(
                        Modifier.size(28.dp).clip(CircleShape).background(VoiidColor.primary),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (uploading) {
                            CircularProgressIndicator(
                                color = VoiidColor.textOnPrimary,
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(16.dp),
                            )
                        } else {
                            Icon(
                                Icons.Default.CameraAlt, "Change photo",
                                tint = VoiidColor.textOnPrimary, modifier = Modifier.size(15.dp),
                            )
                        }
                    }
                }

                if (editingName) {
                    val shape = RoundedCornerShape(VoiidRadius.md)
                    BasicTextField(
                        value = draftName,
                        onValueChange = { draftName = it },
                        singleLine = true,
                        textStyle = VoiidFont.rounded(18, FontWeight.SemiBold)
                            .merge(TextStyle(color = VoiidColor.textPrimary, textAlign = TextAlign.Center)),
                        cursorBrush = SolidColor(VoiidColor.primary),
                        modifier = Modifier.fillMaxWidth().height(48.dp).clip(shape)
                            .background(VoiidColor.fieldFill)
                            .border(1.dp, VoiidColor.fieldBorder, shape)
                            .padding(horizontal = 12.dp),
                        decorationBox = { inner ->
                            Box(contentAlignment = Alignment.Center) {
                                if (draftName.isEmpty()) {
                                    Text("Your name", style = VoiidFont.body, color = VoiidColor.placeholder)
                                }
                                inner()
                            }
                        },
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                        Text(
                            "Cancel", style = VoiidFont.rounded(15, FontWeight.SemiBold),
                            color = VoiidColor.textSecondary,
                            modifier = Modifier.softClickable { editingName = false },
                        )
                        Text(
                            "Save", style = VoiidFont.rounded(15, FontWeight.SemiBold),
                            color = VoiidColor.primary,
                            modifier = Modifier.softClickable { haptics.tap(); saveName() },
                        )
                    }
                } else {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier.softClickable {
                            haptics.tap(); draftName = session.profile.fullName; editingName = true
                        },
                    ) {
                        Text(
                            session.profile.fullName,
                            style = VoiidFont.rounded(20, FontWeight.Bold), color = VoiidColor.textPrimary,
                        )
                        Icon(
                            Icons.Default.Edit, "Edit name",
                            tint = VoiidColor.textSecondary, modifier = Modifier.size(15.dp),
                        )
                    }
                }

                if (session.profile.phoneNumber.isNotBlank()) {
                    Text(
                        session.profile.phoneNumber,
                        style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
                    )
                }
                errorText?.let {
                    Text(
                        it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                        textAlign = TextAlign.Center,
                    )
                }
            }

            // ---- settings rows
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.surfaceCard),
            ) {
                SettingsRow(Icons.Default.VerifiedUser, "Backup & Recovery") { onClose(); onBackupRecovery() }
                SettingsDivider()
                SettingsRow(Icons.Default.PhoneAndroid, "Linked Devices") { onClose(); onLinkedDevices() }
                SettingsDivider()
                // Android owns Voiid's notification behaviour entirely (no in-app toggle
                // duplicates the OS channel list) — this jumps straight to Voiid's
                // notification settings pane, mirroring iOS's
                // UIApplication.openNotificationSettingsURLString deep link.
                SettingsRow(Icons.Default.Notifications, "Notifications") {
                    val intent = android.content.Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
                    runCatching { context.startActivity(intent) }
                }
                SettingsDivider()
                SettingsRow(Icons.Default.Lock, "Privacy") { onClose(); onPrivacy() }
                SettingsDivider()
                SettingsRow(Icons.Default.Storage, "Storage") { onClose(); onStorage() }
                SettingsDivider()
                // Stories: view-receipts opt-in (default OFF). Sending one tells the SERVER you
                // opened someone's story at time T — a fact it otherwise never learns, with no
                // sealed sender to hide it. The opt-out is reciprocal: OFF = you send none AND see
                // none. Written straight to the shared story prefs (see StoryPrefs).
                StoryReceiptsRow()
                SettingsDivider()
                SettingsRow(Icons.Default.Info, "About") { onClose(); onAbout() }
            }

            // ---- danger
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.surfaceCard),
            ) {
                SettingsRow(Icons.AutoMirrored.Filled.Logout, "Log out", tint = VoiidColor.error) {
                    session.signOut(); onClose()
                }
            }
        }
    }
}

@Composable
private fun SettingsRow(icon: ImageVector, title: String, tint: Color = VoiidColor.textPrimary, onClick: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    Row(
        Modifier.fillMaxWidth().height(52.dp)
            .softClickable { haptics.tap(); onClick() }
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(
            icon, null,
            tint = if (tint == VoiidColor.error) VoiidColor.error else VoiidColor.primary,
            modifier = Modifier.size(22.dp),
        )
        Text(title, style = VoiidFont.rounded(16), color = tint, modifier = Modifier.weight(1f))
        Icon(Icons.Default.ChevronRight, null, tint = VoiidColor.placeholder, modifier = Modifier.size(18.dp))
    }
}

/**
 * "Story view receipts" — an inline toggle row (the app has no settings sub-navigation). Copy is
 * verbatim from the spec so nobody softens the reciprocity.
 */
@Composable
private fun StoryReceiptsRow() {
    val context = LocalContext.current
    var on by remember { mutableStateOf(com.voiid.app.model.StoryPrefs.receiptsEnabled(context)) }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(Icons.Default.RemoveRedEye, null, tint = VoiidColor.primary, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f)) {
            Text("Story view receipts", style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
            Text(
                "If you turn this off, people won't know when you've viewed their story — and you " +
                    "won't see who viewed yours.",
                style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
            )
        }
        com.voiid.app.ui.components.VoiidToggle(checked = on) {
            on = it; com.voiid.app.model.StoryPrefs.setReceiptsEnabled(context, it)
        }
    }
}

@Composable
private fun SettingsDivider() {
    Box(
        Modifier.fillMaxWidth().padding(start = 54.dp).height(1.dp)
            .background(VoiidColor.divider.copy(alpha = 0.35f)),
    )
}

/**
 * Round avatar (Chats header + Settings). Falls back to the initials of the name, and only
 * then to a glyph — an avatar that renders as an empty circle reads as a loading bug rather
 * than "no photo set".
 *
 * A `photoUrl` is usually an R2 OBJECT KEY, not an absolute URL, so it needs a presigned GET
 * before it can be drawn (see [MediaService]). Failure is silent on purpose: the initials are
 * a perfectly good avatar, and an error glyph would be noise on every screen showing a face.
 */
@Composable
fun ProfileAvatar(
    photoUrl: String?,
    name: String?,
    size: Dp,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var bitmap by remember(photoUrl) { mutableStateOf(photoUrl?.let { MediaCache.image(it) }) }

    LaunchedEffect(photoUrl) {
        val key = photoUrl?.takeIf { it.isNotBlank() && !it.startsWith("http") } ?: return@LaunchedEffect
        if (bitmap != null) return@LaunchedEffect
        runCatching {
            val bytes = MediaService(TokenStore.get(context)).download(key)
            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@runCatching
            val ib: ImageBitmap = bmp.asImageBitmap()
            MediaCache.putImage(key, ib)
            bitmap = ib
        }
    }

    val initials = (name ?: "").trim().split(" ").filter { it.isNotBlank() }
        .take(2).mapNotNull { it.firstOrNull() }.joinToString("").uppercase()

    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.divider.copy(alpha = 0.4f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        val b = bitmap
        when {
            b != null -> Image(b, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            !photoUrl.isNullOrBlank() && photoUrl.startsWith("http") ->
                coil.compose.AsyncImage(
                    model = photoUrl, contentDescription = null,
                    modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop,
                )
            initials.isNotEmpty() -> Text(
                initials,
                style = VoiidFont.rounded((size.value * 0.36f).toInt().coerceAtLeast(8), FontWeight.SemiBold),
                color = VoiidColor.textSecondary,
            )
            else -> Icon(
                Icons.Default.Person, null, tint = VoiidColor.textSecondary,
                modifier = Modifier.size(size * 0.5f),
            )
        }
    }
}

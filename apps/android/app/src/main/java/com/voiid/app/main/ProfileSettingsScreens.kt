package com.voiid.app.main

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.model.AppSession
import com.voiid.app.net.ProfileService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * The personal link behind a QR code — `https://voiid.app/u/<username>`, the SAME shape iOS
 * builds in ProfileLink.swift. HTTPS only, and the username is validated before it reaches a
 * path so a malformed handle cannot produce a link that resolves somewhere else.
 *
 * The PIN is deliberately never in the link: it is what the other person types to prove the
 * scan was consensual, so putting it in the thing being scanned would defeat it.
 */
internal object ProfileLink {
    private val HANDLE = Regex("^[a-z][a-z0-9_]{2,19}$")

    fun urlFor(username: String?): String? {
        val handle = username?.lowercase()?.removePrefix("@") ?: return null
        if (!HANDLE.matches(handle)) return null
        return "https://voiid.app/u/$handle"
    }
}

/**
 * Edit profile — name, bio and username on one screen, port of iOS `EditProfileView`.
 *
 * Writes LOCALLY FIRST (session + the local users row) and then syncs, so editing your name
 * offline shows the new name immediately and reconciles when the network returns — the rule
 * the rest of the app follows.
 */
@Composable
fun EditProfileScreen(session: AppSession, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = LocalVoiidHaptics.current

    var name by remember { mutableStateOf(session.profile.fullName) }
    var bio by remember { mutableStateOf(session.profile.bio ?: "") }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var saved by remember { mutableStateOf(false) }

    fun save() {
        scope.launch {
            saving = true
            error = null
            val trimmed = name.trim()
            if (trimmed.isEmpty()) {
                error = "Your name can't be empty."
                saving = false
                return@launch
            }
            error = runCatching {
                ProfileService(context).updateProfile(fullName = trimmed, bio = bio.trim())
                null
            }.getOrElse { it.message ?: "Couldn't save. Try again." }
            if (error == null) {
                saved = true
                haptics.tap()
            }
            saving = false
        }
    }

    BackupScaffold(title = "Edit profile", onBack = onBack) {
        Spacer(Modifier.height(8.dp))

        FieldCard("Name") {
            ProfileField(value = name, placeholder = "Your name", onValueChange = { name = it; saved = false })
        }

        FieldCard(
            "Bio",
            footer = "A short line people see on your profile.",
        ) {
            ProfileField(value = bio, placeholder = "Add a few words about you",
                onValueChange = { bio = it; saved = false })
        }

        // Username is READ-ONLY here. It is the handle other people's links and QR codes
        // resolve against, so changing it breaks every link already shared — a different
        // operation from editing a display name, and one that belongs behind its own
        // deliberate flow rather than beside two free-text fields.
        session.profile.username?.let { handle ->
            FieldCard("Username", footer = "This is what your QR code and profile link point to.") {
                Text(
                    "@${handle.removePrefix("@")}",
                    style = VoiidFont.rounded(16),
                    color = VoiidColor.textSecondary,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp),
                )
            }
        }

        error?.let {
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp))
        }

        Spacer(Modifier.height(8.dp))
        Box(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp)
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(if (saving) VoiidColor.fieldFill else VoiidColor.primary)
                .softClickable(enabled = !saving) { save() }
                .padding(vertical = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (saving) "Saving…" else if (saved) "Saved" else "Save",
                style = VoiidFont.rounded(16, FontWeight.SemiBold),
                color = if (saving) VoiidColor.textSecondary else VoiidColor.textOnPrimary,
            )
        }
    }
}

/**
 * My QR code — the scannable form of your profile link, port of iOS `MyQRCodeView`.
 *
 * HIGH error correction and a large raster for the same reason the safety-number card uses
 * them: this is scanned off a screen at an angle, through glare.
 */
@Composable
fun MyQrCodeScreen(session: AppSession, onBack: () -> Unit) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val link = ProfileLink.urlFor(session.profile.username)

    BackupScaffold(title = "My QR code", onBack = onBack) {
        Spacer(Modifier.height(16.dp))

        if (link == null) {
            // An honest empty state rather than a broken code. A QR that encodes nothing
            // scannable is worse than none: it fails at the moment two people are stood
            // together expecting it to work.
            Text(
                "Set a username first — your QR code points at your profile link, and there " +
                    "isn't one until you have a handle.",
                style = VoiidFont.rounded(14),
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp),
            )
            return@BackupScaffold
        }

        val bmp = remember(link) {
            runCatching {
                val hints = mapOf<com.google.zxing.EncodeHintType, Any>(
                    com.google.zxing.EncodeHintType.ERROR_CORRECTION to
                        com.google.zxing.qrcode.decoder.ErrorCorrectionLevel.H,
                    com.google.zxing.EncodeHintType.MARGIN to 1,
                )
                val matrix = com.google.zxing.qrcode.QRCodeWriter()
                    .encode(link, com.google.zxing.BarcodeFormat.QR_CODE, 600, 600, hints)
                val out = android.graphics.Bitmap.createBitmap(600, 600, android.graphics.Bitmap.Config.ARGB_8888)
                for (x in 0 until 600) for (y in 0 until 600) {
                    out.setPixel(x, y, if (matrix.get(x, y)) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
                }
                out
            }.getOrNull()
        }

        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Box(
                Modifier.fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(androidx.compose.ui.graphics.Color.White)
                    .padding(20.dp),
                contentAlignment = Alignment.Center,
            ) {
                if (bmp != null) {
                    Image(
                        bitmap = bmp.asImageBitmap(),
                        contentDescription = "Your Voiid QR code",
                        modifier = Modifier.fillMaxWidth().heightIn(max = 280.dp),
                    )
                } else {
                    Text("Couldn't build the QR code.", style = VoiidFont.rounded(13), color = VoiidColor.error)
                }
            }

            Text(
                "@${session.profile.username?.removePrefix("@")}",
                style = VoiidFont.rounded(20, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
            )
            Text(
                "Have someone scan this to start a chat with you.",
                style = VoiidFont.rounded(13),
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
            )

            LinkActions(link = link, context = context, haptics = haptics)
        }
    }
}

/**
 * Share profile — the same link as a QR, in the forms you can send: copy, or hand to the
 * system share sheet. Port of iOS `ShareProfileView`.
 */
@Composable
fun ShareProfileScreen(session: AppSession, onBack: () -> Unit) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val link = ProfileLink.urlFor(session.profile.username)

    BackupScaffold(title = "Share profile", onBack = onBack) {
        Spacer(Modifier.height(16.dp))

        if (link == null) {
            Text(
                "Set a username first — there's no profile link to share until you have a handle.",
                style = VoiidFont.rounded(14),
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp),
            )
            return@BackupScaffold
        }

        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Column(
                Modifier.fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.surfaceCard)
                    .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.lg))
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text("Your profile link", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                Text(link, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
            }

            LinkActions(link = link, context = context, haptics = haptics)

            Text(
                "Anyone with this link can open your profile and ask to chat. They still have " +
                    "to be accepted, and your contact PIN is never part of the link.",
                style = VoiidFont.rounded(12.5f),
                color = VoiidColor.textSecondary,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }
}

/** Copy + system share, the two things you can actually do with a link. Shared by both screens. */
@Composable
private fun LinkActions(
    link: String,
    context: android.content.Context,
    haptics: com.voiid.app.ui.components.VoiidHaptics,
) {
    var copied by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ActionButton(
            icon = Icons.Default.ContentCopy,
            label = if (copied) "Copied" else "Copy link",
            modifier = Modifier.weight(1f),
        ) {
            haptics.tap()
            val clip = context.getSystemService(android.content.ClipboardManager::class.java)
            clip?.setPrimaryClip(android.content.ClipData.newPlainText("Voiid profile", link))
            copied = true
        }
        ActionButton(
            icon = Icons.Default.Share,
            label = "Share",
            modifier = Modifier.weight(1f),
        ) {
            haptics.tap()
            val send = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(android.content.Intent.EXTRA_TEXT, link)
            }
            runCatching { context.startActivity(android.content.Intent.createChooser(send, null)) }
        }
    }
}

@Composable
private fun ActionButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Row(
        modifier
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.lg))
            .softClickable { onClick() }
            .padding(vertical = 13.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = VoiidColor.primary, modifier = Modifier.size(17.dp))
        Spacer(Modifier.size(8.dp))
        Text(label, style = VoiidFont.rounded(14, FontWeight.Medium), color = VoiidColor.textPrimary)
    }
}

@Composable
private fun FieldCard(header: String, footer: String? = null, content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(header, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
            modifier = Modifier.padding(start = 4.dp))
        Column(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.lg)),
        ) { content() }
        if (footer != null) {
            Text(footer, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                modifier = Modifier.padding(start = 4.dp))
        }
    }
}

@Composable
private fun ProfileField(value: String, placeholder: String, onValueChange: (String) -> Unit) {
    Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp)) {
        if (value.isEmpty()) {
            Text(placeholder, style = VoiidFont.rounded(16), color = VoiidColor.placeholder)
        }
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            textStyle = TextStyle(
                fontSize = androidx.compose.ui.unit.TextUnit(16f, androidx.compose.ui.unit.TextUnitType.Sp),
                color = VoiidColor.textPrimary,
            ),
            cursorBrush = SolidColor(VoiidColor.primary),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

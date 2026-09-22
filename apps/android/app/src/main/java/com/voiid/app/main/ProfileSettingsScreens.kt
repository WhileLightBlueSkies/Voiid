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
import androidx.compose.runtime.LaunchedEffect
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
import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.AlternateEmail
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material3.CircularProgressIndicator
import com.voiid.app.model.AppSession
import com.voiid.app.net.DpdpService
import com.voiid.app.net.MediaService
import com.voiid.app.net.ProfileService
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidDialog
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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

    /**
     * The reverse: a scanned string → the handle it names, or null.
     *
     * HTTPS and voiid.app only, and the handle must satisfy the same rule [urlFor] enforces
     * when writing one. A scanner that followed whatever URL a code contained would be an
     * attack surface — this one either recognises a Voiid profile link or ignores the code.
     */
    fun handleFrom(scanned: String): String? {
        val uri = runCatching { android.net.Uri.parse(scanned.trim()) }.getOrNull() ?: return null
        if (!uri.scheme.equals("https", ignoreCase = true)) return null
        val host = uri.host?.lowercase()?.removePrefix("www.") ?: return null
        if (host != "voiid.app") return null
        val segments = uri.pathSegments ?: return null
        if (segments.size != 2 || segments[0] != "u") return null
        val handle = segments[1].lowercase()
        return if (HANDLE.matches(handle)) handle else null
    }
}

/**
 * Edit profile — name, bio and username on one screen, port of iOS `EditProfileView`.
 *
 * Writes LOCALLY FIRST (session + the local users row) and then syncs, so editing your name
 * offline shows the new name immediately and reconciles when the network returns — the rule
 * the rest of the app follows.
 */
/**
 * Edit profile — name, photo, bio, username, and account deletion. Port of iOS `EditProfileView.swift`.
 *
 * Presentation decision (spec §5.1): a pushed screen with an explicit Save, not inline
 * tap-to-mutate labels. Multi-field inline editing has no cancel-safety.
 *
 * Save is LOCAL FIRST: `session.updateProfile` persists and re-renders before the request
 * is attempted, so editing your name offline shows the new name immediately.
 */
@Composable
fun EditProfileScreen(session: AppSession, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = LocalVoiidHaptics.current

    var name by remember { mutableStateOf(session.profile.fullName) }
    var bio by remember { mutableStateOf(session.profile.bio ?: "") }
    var username by remember { mutableStateOf(session.profile.username ?: "") }
    var usernameAvailable by remember { mutableStateOf<Boolean?>(null) }
    var checkingUsername by remember { mutableStateOf(false) }

    var uploading by remember { mutableStateOf(false) }
    var showPhotoSource by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var saved by remember { mutableStateOf(false) }

    // Account erasure flow state
    var confirmDelete by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }

    fun uploadPhotoBytes(bytes: ByteArray?) {
        scope.launch {
            uploading = true
            error = try {
                if (bytes == null) "Couldn't read that photo." else {
                    val key = MediaService(TokenStore.get(context)).uploadProfilePhoto(bytes)
                    MediaCache.putData(context, key, bytes)
                    session.updateProfile(photoUrl = key)
                    ProfileService(context).updateProfile(photoUrl = key)
                    null
                }
            } catch (e: Exception) {
                "Couldn't update your photo. Try again."
            }
            uploading = false
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val bytes = withContext(Dispatchers.IO) {
                context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
            }
            uploadPhotoBytes(bytes)
        }
    }

    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicturePreview()) { bitmap ->
        if (bitmap == null) return@rememberLauncherForActivityResult
        scope.launch {
            val bytes = withContext(Dispatchers.IO) {
                java.io.ByteArrayOutputStream().use { out ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
                    out.toByteArray()
                }
            }
            uploadPhotoBytes(bytes)
        }
    }

    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) camera.launch(null) else error = "Camera permission needed to take a photo."
    }

    // Debounced live username availability check (400ms, matching iOS EditProfileView.swift)
    LaunchedEffect(username) {
        val u = username.trim().lowercase()
        val current = (session.profile.username ?: "").lowercase()
        if (u == current || u.length < 3) {
            usernameAvailable = null
            checkingUsername = false
            return@LaunchedEffect
        }
        checkingUsername = true
        delay(400)
        usernameAvailable = runCatching { ProfileService(context).checkUsername(u).available }.getOrNull()
        checkingUsername = false
    }

    val trimmedUser = username.trim().lowercase()
    val userChanged = trimmedUser != (session.profile.username ?: "").lowercase()
    val isDirty = name.trim() != session.profile.fullName ||
        bio.trim() != (session.profile.bio ?: "") ||
        (userChanged && usernameAvailable == true)

    val canSave = isDirty && !saving && name.trim().isNotEmpty() && (!userChanged || usernameAvailable == true) && !checkingUsername

    fun save() {
        if (!canSave) return
        scope.launch {
            saving = true
            error = null
            val trimmedName = name.trim()
            val trimmedBio = bio.trim()

            error = runCatching {
                if (userChanged && usernameAvailable == true) {
                    ProfileService(context).updateProfile(fullName = trimmedName, bio = trimmedBio, username = trimmedUser)
                    session.updateProfile(fullName = trimmedName, bio = trimmedBio, username = trimmedUser)
                } else {
                    ProfileService(context).updateProfile(fullName = trimmedName, bio = trimmedBio)
                    session.updateProfile(fullName = trimmedName, bio = trimmedBio)
                }
                null
            }.getOrElse { it.message ?: "Couldn't save. Try again." }

            if (error == null) {
                saved = true
                haptics.tap()
            }
            saving = false
        }
    }

    BackupScaffold(title = "Edit profile", onBack = onBack, actions = {
        androidx.compose.material3.TextButton(onClick = { save() }, enabled = canSave) {
            Text(if (saving) "Saving…" else "Save", style = VoiidFont.rounded(14, FontWeight.SemiBold),
                color = if (canSave) VoiidColor.accentInk else VoiidColor.textSecondary)
        }
    }) {
        Spacer(Modifier.height(8.dp))

        // Avatar change section
        Column(
            Modifier.fillMaxWidth().padding(vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(contentAlignment = Alignment.BottomEnd) {
                ProfileAvatar(
                    photoUrl = session.profile.photoURL,
                    name = session.profile.fullName,
                    size = 96.dp,
                    placeholderFill = VoiidColor.surfaceCard,
                    modifier = Modifier.softClickable(scale = 0.95f) {
                        if (!uploading) { haptics.tap(); showPhotoSource = true }
                    },
                )
                Box(
                    Modifier.size(28.dp).clip(CircleShape).background(VoiidColor.primary),
                    contentAlignment = Alignment.Center,
                ) {
                    if (uploading) {
                        CircularProgressIndicator(color = VoiidColor.textOnPrimary, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                    } else {
                        Icon(Icons.Default.CameraAlt, "Change photo", tint = VoiidColor.textOnPrimary, modifier = Modifier.size(15.dp))
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                "Change photo",
                style = VoiidFont.rounded(14, FontWeight.SemiBold),
                color = VoiidColor.primary,
                modifier = Modifier.softClickable { if (!uploading) { haptics.tap(); showPhotoSource = true } },
            )
        }

        FieldCard("Name", footer = "Your name and photo are shown to everyone you chat with.") {
            ProfileField(value = name, placeholder = "Your name", onValueChange = { name = it.take(50); saved = false })
        }

        FieldCard("Username", footer = "This is what your QR code and profile link point to.") {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text("@", style = VoiidFont.rounded(16), color = VoiidColor.textSecondary)
                BasicTextField(
                    value = username,
                    onValueChange = {
                        username = it.lowercase().filter { c -> c.isLetterOrDigit() || c == '_' }.take(20)
                        saved = false
                    },
                    singleLine = true,
                    textStyle = VoiidFont.rounded(16).copy(color = VoiidColor.textPrimary),
                    cursorBrush = SolidColor(VoiidColor.primary),
                    modifier = Modifier.weight(1f),
                )
                when {
                    checkingUsername -> Text("Checking…", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                    usernameAvailable == false -> Text("Taken", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.error)
                    usernameAvailable == true -> Text("Available", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.primary)
                }
            }
        }

        FieldCard("About", footer = "A short line people see on your profile (${bio.length}/140).") {
            ProfileField(value = bio, placeholder = "Add a few words about you", onValueChange = { bio = it.take(140); saved = false })
        }

        if (session.profile.phoneNumber.isNotBlank()) {
            FieldCard("Phone", footer = "Your phone number is tied to your cryptographic identity.") {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Default.Lock, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(16.dp))
                    Text(session.profile.phoneNumber, style = VoiidFont.rounded(16), color = VoiidColor.textSecondary)
                }
            }
        }

        // Danger zone — exact match to iOS EditProfileView.swift dangerZone
        FieldCard("Danger zone", footer = "Deleting opens an account erasure request and removes this phone’s messages and keys when you are signed out.") {
            Row(
                Modifier.fillMaxWidth()
                    .softClickable { haptics.rigid(); confirmDelete = true }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(Icons.Default.Delete, null, tint = VoiidColor.error, modifier = Modifier.size(18.dp))
                Text("Delete my account", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.error)
            }
        }

        error?.let {
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp))
        }

        Spacer(Modifier.height(24.dp))
    }

    if (showPhotoSource) {
        com.voiid.app.ui.components.VoiidDialogCustom(
            onDismissRequest = { showPhotoSource = false },
        ) {
            Spacer(Modifier.height(20.dp))
            Text(
                "Change photo",
                style = VoiidFont.rounded(17, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
            )
            Spacer(Modifier.height(6.dp))
            com.voiid.app.ui.components.VoiidDialogAction("Take photo") {
                showPhotoSource = false
                cameraPermission.launch(android.Manifest.permission.CAMERA)
            }
            com.voiid.app.ui.components.VoiidDialogAction("Choose from gallery") {
                showPhotoSource = false
                picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            }
            com.voiid.app.ui.components.VoiidDialogAction("Cancel") {
                showPhotoSource = false
            }
            Spacer(Modifier.height(8.dp))
        }
    }

    if (confirmDelete) {
        VoiidDialog(
            onDismissRequest = { if (!deleting) confirmDelete = false },
            title = "Delete your Voiid account?",
            body = "This opens an erasure request and signs you out of this phone immediately, " +
                "wiping its messages and keys. Your account itself is erased once the request " +
                "is actioned — until then you can still sign in and cancel by contacting support.",
            confirmLabel = "Delete my account",
            onConfirm = {
                deleting = true
                scope.launch {
                    try {
                        DpdpService(context).requestErasure()
                        haptics.success()
                        confirmDelete = false
                        session.signOut()
                        onBack()
                    } catch (e: Exception) {
                        error = e.message ?: "Couldn't open erasure request."
                        haptics.error()
                        deleting = false
                    }
                }
            },
            confirmDestructive = true,
        )
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
                    .clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
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

        Spacer(Modifier.height(16.dp))
        PinCard()
        Spacer(Modifier.height(16.dp))
    }
}

/**
 * The contact PIN, shown BESIDE the code and never inside it.
 *
 * A QR is a photograph waiting to happen. Encoding the PIN would mean anyone who ever saw a
 * picture of this screen could reach you, which is exactly what the PIN exists to prevent —
 * scanning alone lands the other person on the PIN step, and the message they then send
 * arrives as a request you still have to accept. Two gates. So the digits are here as text,
 * to be read aloud or sent separately.
 */
@Composable
private fun PinCard() {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    var state by remember { mutableStateOf<com.voiid.app.net.ContactPinService.PinState?>(null) }
    var loading by remember { mutableStateOf(true) }
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        state = runCatching { com.voiid.app.net.ContactPinService(context).state() }.getOrNull()
        loading = false
    }

    val pin = state?.pin

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            if (copied) "Copied" else "Your Contact PIN",
            style = VoiidFont.rounded(13),
            color = VoiidColor.textSecondary,
            modifier = Modifier.padding(start = 4.dp),
        )
        Column(
            Modifier.fillMaxWidth()
                .clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.divider, com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
                .padding(16.dp),
        ) {
            when {
                loading -> Text("…", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)

                pin != null -> Row(
                    Modifier.fillMaxWidth()
                        // TAP TO COPY. Saying the PIN out loud is only one of the two ways to
                        // get it to someone; the other is pasting it into whatever app you are
                        // already talking to them in.
                        .softClickable {
                            haptics.tap()
                            val clip = context.getSystemService(android.content.ClipboardManager::class.java)
                            clip?.setPrimaryClip(android.content.ClipData.newPlainText("Voiid contact PIN", pin))
                            copied = true
                        },
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    // One tile per digit, not one tracked string: the reading task is "say six
                    // digits in order, out loud, to someone who is typing them", and grouping
                    // gives the eye a place to return to after each glance at the other phone.
                    //
                    // SF Pro Rounded like every other glyph in the app — iOS deliberately does
                    // NOT switch to a monospaced face here, because this is the one screen
                    // whose whole job is to be read aloud accurately from your own app.
                    pin.forEach { digit ->
                        Box(
                            Modifier.weight(1f).height(52.dp)
                                .clip(RoundedCornerShape(VoiidRadius.md))
                                .background(VoiidColor.fieldFill),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                digit.toString(),
                                style = VoiidFont.rounded(24, FontWeight.SemiBold),
                                color = VoiidColor.textPrimary,
                            )
                        }
                    }
                }

                state?.has_pin == true -> Text(
                    "Set, but not viewable. Rotate it in Privacy & security to get a PIN you can read.",
                    style = VoiidFont.rounded(14),
                    color = VoiidColor.textSecondary,
                )

                else -> Text(
                    "You don't have one yet. Set it in Privacy & security — without a PIN, " +
                        "people who scan your code can't reach you.",
                    style = VoiidFont.rounded(14),
                    color = VoiidColor.textSecondary,
                )
            }
        }
        Text(
            "Scanning your code is not enough on its own — they also need these digits, " +
                "which is why the code does not contain them. Say the PIN out loud or send " +
                "it separately. You still choose whether to accept.",
            style = VoiidFont.rounded(12),
            color = VoiidColor.textSecondary,
            modifier = Modifier.padding(start = 4.dp),
        )
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
                    .clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
                    .background(VoiidColor.surfaceCard)
                    .border(1.dp, VoiidColor.divider, com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
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
            .clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
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
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val icon = when (header) {
                "Name" -> Icons.Default.Person
                "Username" -> Icons.Default.AlternateEmail
                "About" -> Icons.Default.Info
                "Phone" -> Icons.Default.Phone
                else -> Icons.Default.Delete
            }
            Box(Modifier.size(30.dp).clip(CircleShape).background(VoiidColor.accentTint), Alignment.Center) {
                Icon(icon, null, Modifier.size(15.dp), tint = if (header == "Danger zone") VoiidColor.error else VoiidColor.accentInk)
            }
            Text(header, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        }
        Column(
            Modifier.fillMaxWidth()
                .clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.divider, com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg)),
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

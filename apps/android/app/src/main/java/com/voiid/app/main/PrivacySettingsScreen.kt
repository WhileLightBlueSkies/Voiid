package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.PrivacySettings
import com.voiid.app.model.MapVisibility
import com.voiid.app.net.ContactPinService
import kotlinx.coroutines.launch
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.size
import com.voiid.app.net.MapPresenceEngine
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidToggle
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * Settings -> Privacy. Port of iOS `PrivacySettingsView.swift`.
 *
 * Three toggles backed by [PrivacySettings] (plain SharedPreferences), each with a real
 * consumer elsewhere in the app — see that file's doc for the exact call sites. Plus Map
 * Ghost Mode / kill switch, backed by the real [MapPresenceEngine] singleton (a hard local
 * gate on the location provider, not a display filter).
 *
 * Deliberately absent, mirroring iOS: no blocking, last-seen visibility, profile-photo
 * visibility, disappearing messages, screenshot blocking, app lock, or "who can add me to
 * groups" — none of those has a schema, a route or a line of client code in this project.
 */
@Composable
fun PrivacySettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current

    var sendReceipts by remember { mutableStateOf(PrivacySettings.sendReadReceipts(context)) }
    var sendTyping by remember { mutableStateOf(PrivacySettings.sendTypingIndicators(context)) }
    var showOnline by remember { mutableStateOf(PrivacySettings.showOnlineStatus(context)) }
    var lastSeenVis by remember { mutableStateOf(PrivacySettings.lastSeenVisibility(context)) }
    var photoVis by remember { mutableStateOf(PrivacySettings.photoVisibility(context)) }
    var aboutVis by remember { mutableStateOf(PrivacySettings.aboutVisibility(context)) }
    val mapVisibility by MapPresenceEngine.visibility.collectAsState()
    val haptics = LocalVoiidHaptics.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    // Contact PIN — how someone who finds you by @username is allowed to message you.
    var pinSet by remember { mutableStateOf<Boolean?>(null) }
    var revealedPin by remember { mutableStateOf<String?>(null) }
    var pinBusy by remember { mutableStateOf(false) }
    var pinError by remember { mutableStateOf<String?>(null) }
    var confirmRotate by remember { mutableStateOf(false) }

    // Only whether a PIN EXISTS — the hash is one-way, so the digits genuinely cannot be
    // re-read. Revealing means rotating.
    androidx.compose.runtime.LaunchedEffect(Unit) {
        pinSet = runCatching { ContactPinService(context).state().has_pin }.getOrNull()
    }

    fun rotatePin() {
        pinBusy = true
        pinError = null
        scope.launch {
            runCatching { ContactPinService(context).rotate() }
                .onSuccess { revealedPin = it; pinSet = true }
                // Say what failed: a silent no-op on a security control is worse than an error.
                .onFailure { pinError = "Couldn't generate a PIN. Check your connection and try again." }
            pinBusy = false
        }
    }

    if (confirmRotate) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmRotate = false },
            containerColor = VoiidColor.surfaceCard,
            title = { Text("Generate a new PIN?", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary) },
            text = {
                Text(
                    "Anyone who has your current PIN will no longer be able to reach you with it.",
                    style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
                )
            },
            confirmButton = {
                androidx.compose.material3.TextButton(onClick = { confirmRotate = false; rotatePin() }) {
                    Text("Generate", color = VoiidColor.error)
                }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { confirmRotate = false }) {
                    Text("Cancel", color = VoiidColor.textSecondary)
                }
            },
        )
    }

    BackupScaffold(title = "Privacy", onBack = onBack) {
        Spacer(Modifier.height(8.dp))

        PrivacySection(
            header = "Contact PIN",
            footer = "People who find you by @username need this 6-digit PIN before they can " +
                "send you anything — and you still choose whether to accept. Share it the way " +
                "you'd share your number.\n\n" +
                "Anyone saved in your contacts (who has also saved you) can message you " +
                "without it.\n\n" +
                "Voiid stores only a hash, so the PIN can't be shown again after this. " +
                "Generating a new one immediately stops the old one working for everyone who " +
                "had it.",
        ) {
            val pin = revealedPin
            if (pin != null) {
                // The ONE moment the plaintext exists outside the owner's head. No endpoint
                // can read it back, which is what makes rotation a real revocation.
                Column(Modifier.fillMaxWidth().padding(16.dp)) {
                    Text("Your new PIN", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        pin.toCharArray().joinToString(" "),
                        style = VoiidFont.rounded(30, FontWeight.SemiBold),
                        color = VoiidColor.primary,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "Write this down now — it can't be shown again.",
                        style = VoiidFont.rounded(12), color = VoiidColor.warning,
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        "Done",
                        style = VoiidFont.rounded(15, FontWeight.SemiBold),
                        color = VoiidColor.primary,
                        modifier = Modifier.clickable { revealedPin = null },
                    )
                }
            } else {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Contact PIN", style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
                    Spacer(Modifier.weight(1f))
                    Text(
                        if (pinSet == true) "Set" else "Not set",
                        style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
                    )
                }
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable(enabled = !pinBusy) {
                            haptics.tap()
                            // Replacing an existing PIN locks out everyone holding the old
                            // one, so it is confirmed. The first one cannot break anything.
                            if (pinSet == true) confirmRotate = true else rotatePin()
                        }
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        if (pinSet == true) "Generate a new PIN" else "Create a PIN",
                        style = VoiidFont.rounded(16), color = VoiidColor.primary,
                    )
                    if (pinBusy) {
                        Spacer(Modifier.weight(1f))
                        androidx.compose.material3.CircularProgressIndicator(
                            modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = VoiidColor.primary,
                        )
                    }
                }
            }
            pinError?.let {
                Text(
                    it, style = VoiidFont.rounded(12), color = VoiidColor.error,
                    modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 12.dp),
                )
            }
        }
        Spacer(Modifier.height(24.dp))

        // Server-enforced "who can see". GET /users/:id and /users/status/:id apply these
        // (via the contact_sync relationship) so other people don't receive what you hide.
        PrivacySection(
            header = "Who can see my info",
            footer = "Choose who can see your last seen & online, profile photo, and about. " +
                "\"My Contacts\" means people you've saved. This is enforced on the server.\n\n" +
                "Your messages, calls, and the photos, videos and voice notes you send are " +
                "end-to-end encrypted — Voiid can't read them. Your profile photo is not: it's " +
                "stored on Voiid's servers so anyone you allow can load it.",
        ) {
            PrivacyVisibilityRow("Last seen & online", lastSeenVis) {
                lastSeenVis = it; PrivacySettings.setLastSeenVisibility(context, it)
            }
            PrivacyVisibilityRow("Profile photo", photoVis) {
                photoVis = it; PrivacySettings.setPhotoVisibility(context, it)
            }
            PrivacyVisibilityRow("About", aboutVis) {
                aboutVis = it; PrivacySettings.setAboutVisibility(context, it)
            }
        }

        Spacer(Modifier.height(20.dp))

        PrivacySection(
            header = "Message receipts",
            footer = "When these are off, this device stops sending read receipts and " +
                "typing indicators. It doesn't stop them arriving from other people — Voiid " +
                "has no setting for that — so you'll still see when someone is typing or has " +
                "read your message.",
        ) {
            PrivacyToggleRow("Send read receipts", sendReceipts) {
                sendReceipts = it; PrivacySettings.setSendReadReceipts(context, it)
            }
            PrivacyToggleRow("Send typing indicators", sendTyping) {
                sendTyping = it; PrivacySettings.setSendTypingIndicators(context, it)
            }
        }

        Spacer(Modifier.height(20.dp))

        PrivacySection(
            header = "Online status",
            footer = "Hides the online and last-seen line at the top of a chat. This changes " +
                "only what you see on this device — Voiid has no way to hide your own online " +
                "status from other people.",
        ) {
            PrivacyToggleRow("Show when contacts are online", showOnline) {
                showOnline = it; PrivacySettings.setShowOnlineStatus(context, it)
            }
        }

        Spacer(Modifier.height(20.dp))

        PrivacySection(
            header = "Map location",
            footer = "Ghost Mode hides you from everyone on the Map and stops your location " +
                "being taken at all — it's a hard switch, not a filter. You're hidden by " +
                "default and only ever visible to people you pick by name on the Map tab.",
        ) {
            PrivacyToggleRow("Ghost Mode", mapVisibility == MapVisibility.GHOST) { ghost ->
                haptics.tap()
                if (ghost) MapPresenceEngine.goGhost(0L) else MapPresenceEngine.goVisible()
            }
            Row(
                Modifier.fillMaxWidth()
                    .softClickable { haptics.tap(); MapPresenceEngine.killSwitch() }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            ) {
                Text("Stop all location sharing", style = VoiidFont.rounded(15), color = VoiidColor.error)
            }
        }
    }
}

@Composable
private fun PrivacySection(header: String, footer: String, content: @Composable () -> Unit) {
    Text(header, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary)
    Spacer(Modifier.height(8.dp))
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard),
        content = { content() },
    )
    Spacer(Modifier.height(8.dp))
    Text(footer, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
}

@Composable
private fun PrivacyToggleRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(title, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
        VoiidToggle(checked = checked, onCheckedChange = onChange)
    }
}

/** A "who can see" row: title on top, a 3-way segmented selector below. */
@Composable
private fun PrivacyVisibilityRow(
    title: String,
    selected: PrivacySettings.Visibility,
    onSelect: (PrivacySettings.Visibility) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
        Text(title, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
        Spacer(Modifier.height(8.dp))
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(VoiidColor.fieldFill),
        ) {
            PrivacySettings.Visibility.entries.forEach { v ->
                val active = v == selected
                Box(
                    Modifier.weight(1f).height(34.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (active) VoiidColor.primary else androidx.compose.ui.graphics.Color.Transparent)
                        .softClickable { haptics.tap(); onSelect(v) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        v.label,
                        style = VoiidFont.rounded(13, FontWeight.Medium),
                        color = if (active) VoiidColor.textOnPrimary else VoiidColor.textSecondary,
                    )
                }
            }
        }
    }
}

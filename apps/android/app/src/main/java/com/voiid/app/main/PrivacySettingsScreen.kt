package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.model.MapVisibility
import com.voiid.app.model.PrivacySettings
import com.voiid.app.net.BlockService
import com.voiid.app.net.ContactPinService
import com.voiid.app.net.MapPresenceEngine
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidToggle
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * Settings -> Privacy. Port of iOS `PrivacySettingsView.swift`.
 *
 * Three toggles backed by [PrivacySettings] (plain SharedPreferences), each with a real
 * consumer elsewhere in the app — see that file's doc for the exact call sites. Plus Map
 * Ghost Mode / kill switch, backed by the real [MapPresenceEngine] singleton (a hard local
 * gate on the location provider, not a display filter).
 *
 * Deliberately absent, mirroring iOS: no disappearing messages, screenshot blocking, app
 * lock, or "who can add me to groups" — none of those has a schema, a route or a line of
 * client code in this project.
 *
 * Blocking IS here now (043_user_blocks + /blocks, enforced server-side). It gets a row
 * rather than a toggle, because blocking is per-person: the switch lives on each person's
 * profile, and this screen is where you see the list and undo it.
 */
@Composable
fun PrivacySettingsScreen(onBack: () -> Unit, onBlockedContacts: () -> Unit = {}) {
    val context = LocalContext.current
    val blockedUsers by BlockService.blocked.collectAsState()
    val blocksLoaded by BlockService.didLoad.collectAsState()
    LaunchedEffect(Unit) { BlockService.loadIfNeeded(context) }

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
    var pinState by remember { mutableStateOf<ContactPinService.PinState?>(null) }
    var pinBusy by remember { mutableStateOf(false) }
    var pinError by remember { mutableStateOf<String?>(null) }
    var confirmRotate by remember { mutableStateOf(false) }

    // Includes the PIN itself since migration 026 — owner-only, keyed on the auth token
    // server-side.
    androidx.compose.runtime.LaunchedEffect(Unit) {
        pinState = runCatching { ContactPinService(context).state() }.getOrNull()
    }

    fun rotatePin() {
        pinBusy = true
        pinError = null
        scope.launch {
            runCatching {
                ContactPinService(context).rotate()
                // Re-read rather than trusting the rotate response: state() is the one place
                // that knows whether the new PIN is actually viewable, so the card never
                // claims a PIN is stored readably when the server couldn't do it.
                ContactPinService(context).state()
            }
                .onSuccess { pinState = it; haptics.tap() }
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

        // ONE short footer, not three paragraphs. The old copy explained the storage model,
        // the mutual-contact exception and the rotation semantics before the user had seen
        // their own PIN — a wall of text where a number belongs. The card shows the PIN; the
        // sentence says what it's for; the rotation caveat moved to the confirm dialog, where
        // it actually applies.
        PrivacySection(
            header = "Contact PIN",
            footer = "Share this with people who find you by @username. They'll need it to " +
                "message you — and you still choose whether to accept.",
        ) {
            ContactPinCard(
                pin = pinState?.pin,
                hasPin = pinState?.has_pin == true,
                storageConfigured = pinState?.storage_configured != false,
                busy = pinBusy,
                onRegenerate = {
                    haptics.tap()
                    // Replacing an existing PIN locks out everyone holding the old one, so it
                    // is confirmed. The first one cannot break anything.
                    if (pinState?.has_pin == true) confirmRotate = true else rotatePin()
                },
            )
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

        // A row, not a toggle: blocking is per-person and starts on that person's profile.
        // This is the way back — you should not have to find someone you have been avoiding
        // in order to stop avoiding them.
        PrivacySection(
            header = "Blocked",
            footer = "Blocked people can't message or call you, and you can't message or " +
                "call them. They're never told.",
        ) {
            Row(
                Modifier.fillMaxWidth()
                    .softClickable { haptics.tap(); onBlockedContacts() }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Blocked contacts",
                     style = VoiidFont.rounded(15),
                     color = VoiidColor.textPrimary,
                     modifier = Modifier.weight(1f))
                // Only once loaded, and only when non-zero: a "0" beside a settings row
                // invites the question of what it counts.
                if (blocksLoaded && blockedUsers.isNotEmpty()) {
                    Text("${blockedUsers.size}",
                         style = VoiidFont.rounded(15),
                         color = VoiidColor.textSecondary)
                }
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

/**
 * The PIN, shown as a number rather than described in a paragraph. Mirrors the iOS
 * `ContactPinCard` in PrivacySettingsView.swift — same structure, same copy.
 *
 * Since migration 026 the PIN is stored encrypted rather than hashed, so it can be read back —
 * which is what lets this be a display surface instead of a one-shot reveal. The digits are the
 * largest thing on screen because reading them aloud or copying them is the entire task.
 */
@Composable
private fun ContactPinCard(
    pin: String?,
    hasPin: Boolean,
    /** False when the SERVER cannot store a PIN readably (no secretbox key). */
    storageConfigured: Boolean,
    busy: Boolean,
    onRegenerate: () -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    var copied by remember { mutableStateOf(false) }

    // Revert on its own. A permanently "Copied" button stops being a control.
    androidx.compose.runtime.LaunchedEffect(copied) {
        if (copied) { kotlinx.coroutines.delay(1600); copied = false }
    }

    Column(Modifier.fillMaxWidth().padding(16.dp)) {
        when {
            pin != null -> {
                // Grouped 3 + 3: six undifferentiated digits are meaningfully harder to read
                // aloud and to check against what you just typed.
                Text(
                    text = pin.take(3) + "  " + pin.drop(3),
                    style = VoiidFont.rounded(34, FontWeight.SemiBold)
                        .copy(letterSpacing = 4.sp),
                    color = VoiidColor.textPrimary,
                    modifier = Modifier
                        .fillMaxWidth()
                        // Read as separate digits, not "four hundred eighteen thousand".
                        .semantics {
                            contentDescription = "Your contact PIN is " + pin.toCharArray().joinToString(" ")
                        },
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(16.dp))
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    PinAction(
                        label = if (copied) "Copied" else "Copy",
                        tint = if (copied) VoiidColor.success else VoiidColor.primary,
                        modifier = Modifier.weight(1f),
                    ) {
                        val cm = context.getSystemService(android.content.ClipboardManager::class.java)
                        cm?.setPrimaryClip(android.content.ClipData.newPlainText("Voiid PIN", pin))
                        haptics.tap()
                        copied = true
                    }
                    Box(Modifier.width(1.dp).height(20.dp).background(VoiidColor.divider))
                    // "New PIN", not "Regenerate": this REPLACES the PIN and cuts off everyone
                    // holding the old one, and the label should not sound like a refresh.
                    PinAction(
                        label = "New PIN",
                        tint = if (busy) VoiidColor.textSecondary else VoiidColor.primary,
                        enabled = !busy,
                        modifier = Modifier.weight(1f),
                        onClick = onRegenerate,
                    )
                }
            }
            hasPin && !storageConfigured -> {
                // The SERVER cannot store PINs readably. Rotating would not help — it would
                // mint another unviewable one — so this does not offer it as the fix, and
                // names the missing setting so whoever runs the deployment can act.
                Text(
                    "Your PIN is set and works, but this server can't display it. " +
                        "VOIID_SECRETBOX_KEY isn't configured.",
                    style = VoiidFont.rounded(13), color = VoiidColor.warning,
                )
                Spacer(Modifier.height(12.dp))
                PinAction("Generate a new PIN", VoiidColor.primary, !busy, onClick = onRegenerate)
            }
            hasPin -> {
                // Set before 026, so it exists only as a hash and genuinely cannot be shown.
                // Say that plainly instead of rendering an empty card that looks broken.
                Text(
                    "Your PIN is set but can't be shown — it was created before PINs became " +
                        "viewable. Generate a new one to see it here.",
                    style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                )
                Spacer(Modifier.height(12.dp))
                PinAction("Generate a viewable PIN", VoiidColor.primary, !busy, onClick = onRegenerate)
            }
            else -> {
                Text(
                    "You don't have a PIN yet, so nobody can reach you by @username.",
                    style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                )
                Spacer(Modifier.height(12.dp))
                PinAction("Create a PIN", VoiidColor.primary, !busy, onClick = onRegenerate)
            }
        }
        if (busy) {
            Spacer(Modifier.height(10.dp))
            androidx.compose.material3.CircularProgressIndicator(
                modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = VoiidColor.primary,
            )
        }
    }
}

@Composable
private fun PinAction(
    label: String,
    tint: androidx.compose.ui.graphics.Color,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .clip(RoundedCornerShape(VoiidRadius.sm))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = VoiidFont.rounded(15, FontWeight.Medium), color = tint)
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

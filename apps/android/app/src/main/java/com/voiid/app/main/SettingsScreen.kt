package com.voiid.app.main

import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import com.voiid.app.main.walkthrough.SpotlightShapeType
import com.voiid.app.main.walkthrough.spotlightTarget
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.GridView
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
import kotlinx.coroutines.delay
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
    onLegal: () -> Unit,
    onEditProfile: () -> Unit,
    onShareProfile: () -> Unit,
    onMyQrCode: () -> Unit,
    onSafetyNumber: () -> Unit,
    onHelp: () -> Unit,
    onChatSettings: () -> Unit,
    onAccountCentre: () -> Unit,
    onSocialProfile: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // Logout confirmation state. backupExists: true = a server backup exists (restorable with
    // the recovery phrase), false = definitively none, null = couldn't tell.
    var confirmLogout by remember { mutableStateOf(false) }
    var backupExists by remember { mutableStateOf<Boolean?>(null) }

    Column(
        Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding(),
    ) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp).height(56.dp), verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.width(56.dp))
            Text("Settings", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            androidx.compose.material3.TextButton(onClick = onClose) { Text("Done", color = VoiidColor.accentInk) }
        }

        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState())
                .padding(24.dp).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            // ---- profile card
            Row(
                Modifier.fillMaxWidth()
                    .spotlightTarget("settings_profile_card", shape = SpotlightShapeType.ROUNDED_RECT, cornerRadius = 24.dp, padding = 4.dp)
                    .clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
                    .background(VoiidColor.surfaceCard)
                    .padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                ProfileAvatar(
                    photoUrl = session.profile.photoURL,
                    name = session.profile.fullName,
                    size = 84.dp,
                    placeholderFill = VoiidColor.surfaceCard,
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(
                        text = session.profile.fullName.ifBlank { "Add your name" },
                        style = VoiidFont.rounded(18, FontWeight.Bold),
                        color = if (session.profile.fullName.isBlank()) VoiidColor.placeholder else VoiidColor.textPrimary,
                        maxLines = 1,
                    )
                    if (!session.profile.username.isNullOrBlank()) {
                        Text(
                            text = "@${session.profile.username}",
                            style = VoiidFont.rounded(14),
                            color = VoiidColor.textSecondary,
                            maxLines = 1,
                        )
                    }
                    if (session.profile.phoneNumber.isNotBlank()) {
                        Text(
                            text = session.profile.phoneNumber,
                            style = VoiidFont.rounded(13),
                            color = VoiidColor.textSecondary,
                            maxLines = 1,
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        androidx.compose.material3.TextButton(onClick = onEditProfile) { Text("Edit profile", style = VoiidFont.rounded(12), color = VoiidColor.accentInk) }
                        androidx.compose.material3.IconButton(onClick = onMyQrCode) { Icon(Icons.Default.QrCode, "My QR code", tint = VoiidColor.accentInk) }
                    }
                }

            }

            // ---- quick actions + encryption banner (iOS parity)
            //
            // The three things people come to Settings to DO, lifted out of the list so they
            // are one tap rather than a scan-and-push. Same trio and same order as iOS.
            SettingsGroup("Share") {
                SettingsRow(Icons.Default.Person, "Account centre", "Chat and social profiles") { onAccountCentre() }
                SettingsDivider()
                SettingsRow(Icons.Default.Share, "Share profile", "Send your profile link") { onShareProfile() }
            }

            EncryptionBanner(onClick = onSafetyNumber)

            // ---- settings rows
            //
            // FOUR NAMED GROUPS, matching iOS's SettingsSheet exactly: Account → Chats &
            // notifications → Voiid ecosystem → Support & more. Order follows Apple's
            // gradient — who you are, then what protects your account, then how the app
            // behaves, then what it is, then how you leave. One undifferentiated card (what
            // this was) makes ten unrelated rows read as one list and buries the account
            // controls among the informational ones.
            SettingsGroup("Account") {
                // Your identity, at the top of the list — iOS's first row. Everything it
                // owns (name, username, photo, bio) is real and lives on Edit Profile;
                // iOS's own `.account` route is an unwired placeholder for the parts that
                // have no endpoint yet (changing a phone number, adding an email), so this
                // points at the screen that works instead of porting the placeholder.
                SettingsRow(Icons.Default.Person, "Social profile",
                    "View and edit your public profile") { onSocialProfile() }
                SettingsDivider()
                SettingsRow(Icons.Default.Lock, "Privacy & security",
                    "Visibility, blocked contacts, app lock") { onPrivacy() }
            }

            SettingsGroup("Chats & notifications") {
                // A "Chats" ROW, matching iOS, rather than the two toggles inline. Keeping
                // them on the root made this group read as a different shape from every
                // other one — two full-width segmented controls wedged between plain rows —
                // and put appearance controls at the same depth as Storage and
                // Notifications, which are doors. The preferences themselves are unchanged;
                // they now live on the screen the row opens.
                SettingsRow(Icons.Default.Edit, "Chats",
                    "Chat list layout, appearance") { onChatSettings() }
                SettingsDivider()
                SettingsRow(Icons.Default.Storage, "Storage & data",
                    "Manage storage, data usage") { onStorage() }
                SettingsDivider()
                // Android owns Voiid's notification behaviour entirely (no in-app toggle
                // duplicates the OS channel list) — this jumps straight to Voiid's
                // notification settings pane, mirroring iOS's
                // UIApplication.openNotificationSettingsURLString deep link. It is not a
                // route on either platform, which is why it carries no chevron.
                SettingsRow(Icons.Default.Notifications, "Notifications",
                    "Sounds, badges, previews") {
                    val intent = android.content.Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
                    runCatching { context.startActivity(intent) }
                }
            }

            SettingsGroup("Voiid ecosystem") {
                // NO "Voiid One" and NO "Payments" row, for the same reason iOS has neither:
                // absent features get no pixels. Voiid One is not a product, and Razorpay is
                // wired on the server with no client surface that consumes it.
                SettingsRow(Icons.Default.VerifiedUser, "Backup & Recovery",
                    "Encrypted backup & restore") { onBackupRecovery() }
                SettingsDivider()
                SettingsRow(Icons.Default.PhoneAndroid, "Devices",
                    "Linked devices, sessions") { onLinkedDevices() }
            }

            SettingsGroup("Support & more") {
                SettingsRow(Icons.AutoMirrored.Filled.HelpOutline, "Help & support",
                    "FAQ, contact us") { onHelp() }
                SettingsDivider()
                // Above About, not below: "what may Voiid see, and can I take that back" is
                // a question people go looking for, and About is a terminal informational
                // screen nobody scrolls past. It sits at root depth rather than inside
                // Privacy because DPDP s.6(4) requires withdrawing consent to be as easy as
                // giving it was, and giving it was one tick on one screen.
                SettingsRow(Icons.Default.Shield, "Privacy & Legal",
                    "Notice, terms, withdraw consent") { onLegal() }
                SettingsDivider()
                SettingsRow(Icons.Default.Info, "About Voiid",
                    "Version, terms, privacy policy") { onAbout() }
            }

            // ---- danger
            Column(
                Modifier.fillMaxWidth().clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
                    .background(VoiidColor.surfaceCard),
            ) {
                // NOT immediate: logging out wipes this device's messages and keys, so it is
                // confirmed — and the warning says the truth about recoverability, which has
                // THREE states (backed up / never backed up / unknown). Mirrors iOS.
                SettingsRow(Icons.AutoMirrored.Filled.Logout, "Log out", tint = VoiidColor.error) {
                    haptics.rigid()
                    backupExists = null          // re-probe each time the dialog opens
                    confirmLogout = true
                }
            }
        }
    }

    if (confirmLogout) {
        com.voiid.app.ui.components.VoiidDialog(
            onDismissRequest = { confirmLogout = false },
            title = "Log out of Voiid?",
            // Two real variants plus an honest unknown. Telling someone their keys are
            // recoverable when no backup exists is exactly the lie this confirmation
            // exists to prevent.
            body = when (backupExists) {
                true -> "Your messages and encryption keys will be removed from this phone. You can restore them with your recovery phrase."
                false -> "Your messages and encryption keys will be removed from this phone. You haven't backed them up, so they can't be recovered."
                null -> "Your messages and encryption keys will be removed from this phone. They can only be restored if you have a backup and your recovery phrase."
            },
            confirmLabel = "Log out",
            onConfirm = {
                confirmLogout = false
                session.signOut()
                onClose()
            },
            confirmDestructive = true,
        )
    }
}

@Composable
private fun SettingsRow(
    icon: ImageVector,
    title: String,
    detail: String? = null,
    tint: Color = VoiidColor.textPrimary,
    enabled: Boolean = true,
    trailing: (@Composable () -> Unit)? = null,
    onClick: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    Row(
        Modifier.fillMaxWidth()
            // Taller when a subtitle is present, exactly as the iOS row grows to fit its
            // detail line rather than compressing both into the single-line height.
            .heightIn(min = if (detail == null) 52.dp else 60.dp)
            .softClickable(enabled = enabled) { haptics.tap(); onClick() }
            .padding(horizontal = 16.dp, vertical = if (detail == null) 0.dp else 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(
            icon, null,
            tint = if (tint == VoiidColor.error) VoiidColor.error else VoiidColor.primary,
            modifier = Modifier.size(22.dp),
        )
        Column(Modifier.weight(1f)) {
            Text(title, style = VoiidFont.rounded(16), color = tint)
            // The subtitle is what makes the root readable as a list of DOORS rather than a
            // list of words: it says what is actually behind the row. iOS carries one on
            // every route row, so Android does too.
            if (detail != null) {
                Text(detail, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
            }
        }
        if (trailing != null) trailing() else Icon(Icons.Default.ChevronRight, null, tint = VoiidColor.placeholder, modifier = Modifier.size(18.dp))
    }
}

/**
 * The three actions people open Settings to perform, as one card of equal columns —
 * iOS's `quickActions`. Circles are STROKED rather than filled: this strip sits directly
 * under the avatar, and three filled discs there would compete with it for the eye.
 */
@Composable
private fun QuickActions(
    onEditProfile: () -> Unit,
    onShareProfile: () -> Unit,
    onMyQrCode: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
            .padding(vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        QuickAction(Icons.Default.Person, "Edit profile", Modifier.weight(1f), onEditProfile)
        QuickDivider()
        QuickAction(Icons.Default.Share, "Share profile", Modifier.weight(1f), onShareProfile)
        QuickDivider()
        QuickAction(Icons.Default.QrCode, "My QR code", Modifier.weight(1f), onMyQrCode)
    }
}

@Composable
private fun QuickAction(
    icon: ImageVector,
    label: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    Column(
        modifier.softClickable { haptics.tap(); onClick() },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            Modifier.size(40.dp)
                .border(1.5.dp, VoiidColor.accent, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, tint = VoiidColor.accentInk, modifier = Modifier.size(17.dp))
        }
        Text(
            label,
            style = VoiidFont.rounded(11),
            color = VoiidColor.textPrimary,
            maxLines = 1,
        )
    }
}

@Composable
private fun QuickDivider() {
    Box(Modifier.width(1.dp).height(44.dp).background(VoiidColor.divider))
}

/**
 * The one piece of reassurance on this screen, and a door to the safety number that proves
 * it. Tinted rather than plain-carded so it reads as a STATEMENT rather than another row —
 * the same treatment iOS gives it.
 */
@Composable
private fun EncryptionBanner(onClick: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    Row(
        Modifier.fillMaxWidth()
            .clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
            .background(VoiidColor.accent.copy(alpha = 0.06f))
            .border(1.dp, VoiidColor.accent.copy(alpha = 0.30f), com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
            .softClickable { haptics.tap(); onClick() }
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Box(
            Modifier.size(44.dp).clip(CircleShape).background(VoiidColor.accent.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Default.VerifiedUser, null, tint = VoiidColor.accentInk, modifier = Modifier.size(19.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                "You're protected with end-to-end encryption",
                style = VoiidFont.rounded(14, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
            )
            Text(
                "Your chats, calls and data are always private.",
                style = VoiidFont.rounded(12.5f),
                color = VoiidColor.textSecondary,
            )
        }
    }
}

/**
 * A titled card of rows — the iOS `group(_:rows:)` shape: a 13pt secondary header inset from
 * the card's edge, then the rows inside one rounded, hairline-stroked surface.
 *
 * Grouping alone carries the structure at the root (no footers), which is what Settings.app,
 * Signal and WhatsApp all do: footers are explanatory apparatus and belong on the screen where
 * the setting lives, not on a list of doors.
 */
@Composable
private fun SettingsGroup(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            title,
            style = VoiidFont.rounded(13),
            color = VoiidColor.textSecondary,
            modifier = Modifier.padding(start = 4.dp),
        )
        Column(
            Modifier.fillMaxWidth()
                .clip(com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.divider, com.voiid.app.ui.theme.SquircleShape(VoiidRadius.lg)),
            content = content,
        )
    }
}

/**
 * "Moment view receipts" — an inline toggle row (the app has no settings sub-navigation). Copy is
 * verbatim from the spec so nobody softens the reciprocity.
 */
@Composable
internal fun ChatLayoutRow() {
    val context = LocalContext.current
    val current = com.voiid.app.ui.theme.ChatLayoutPreference.layout
    val haptics = LocalVoiidHaptics.current
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.GridView, null, tint = VoiidColor.textPrimary, modifier = Modifier.size(20.dp))
            Spacer(Modifier.size(14.dp))
            Text("Chat list", style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
        }
        Spacer(Modifier.size(10.dp))
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidColor.fieldFill)
                .padding(3.dp),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            com.voiid.app.ui.theme.ChatLayout.entries.forEach { l ->
                val selected = l == current
                Box(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(VoiidRadius.sm))
                        .background(if (selected) VoiidColor.primary else Color.Transparent)
                        .clickable {
                            haptics.selection()
                            com.voiid.app.ui.theme.ChatLayoutPreference.set(context, l)
                        }
                        .padding(vertical = 9.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        l.label,
                        style = VoiidFont.rounded(13, if (selected) FontWeight.SemiBold else FontWeight.Medium),
                        color = if (selected) VoiidColor.textOnPrimary else VoiidColor.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
internal fun AppearanceRow() {
    val context = LocalContext.current
    val current = com.voiid.app.ui.theme.VoiidThemeStore.mode
    val haptics = LocalVoiidHaptics.current
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.DarkMode, null, tint = VoiidColor.textPrimary, modifier = Modifier.size(20.dp))
            Spacer(Modifier.size(14.dp))
            Text("Appearance", style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
        }
        Spacer(Modifier.size(10.dp))
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidColor.fieldFill)
                .padding(3.dp),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            com.voiid.app.ui.theme.VoiidThemeMode.entries.forEach { m ->
                val selected = m == current
                Box(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(VoiidRadius.sm))
                        .background(if (selected) VoiidColor.primary else Color.Transparent)
                        .clickable {
                            haptics.selection()
                            com.voiid.app.ui.theme.VoiidThemeStore.set(context, m)
                        }
                        .padding(vertical = 9.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        m.name.lowercase().replaceFirstChar { it.uppercase() },
                        style = VoiidFont.rounded(13, if (selected) FontWeight.SemiBold else FontWeight.Medium),
                        color = if (selected) VoiidColor.textOnPrimary else VoiidColor.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
internal fun StoryReceiptsRow() {
    val context = LocalContext.current
    var on by remember { mutableStateOf(com.voiid.app.model.StoryPrefs.receiptsEnabled(context)) }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(Icons.Default.RemoveRedEye, null, tint = VoiidColor.primary, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f)) {
            Text("Moment view receipts", style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
            Text(
                "If you turn this off, people won't know when you've viewed their moment — and you " +
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
    /**
     * FILL A RECTANGULAR FRAME instead of clipping to a circle.
     *
     * The avatar is a circle almost everywhere, so that stays the default and every existing
     * call site is untouched. The contact profile's full-bleed portrait is the exception: it
     * needs the photo to fill a 360dp banner, and the hard-coded `.size(size)` +
     * `.clip(CircleShape)` squeezed it into a circle in the corner of that space. Mirrors iOS
     * `ProfileAvatarButton.fillsFrame`.
     */
    fillsFrame: Boolean = false,
    /**
     * The disc drawn behind the initials when there is no photo.
     *
     * DEFAULTS TO `fieldFill`, which is right on a plain ground — but wrong ON A CARD. In
     * dark mode `fieldFill` (#1A1A1A) is a step darker than `surfaceCard` (#121212)… so an
     * avatar placed on a card punched a visibly darker circle into it, with the hairline
     * border on top making it a third edge. That is the "dual tone" on the profile selector.
     * Callers sitting on a card pass that card's colour and the avatar reads as one surface.
     */
    placeholderFill: Color? = null,
) {
    val context = LocalContext.current
    var bitmap by remember(photoUrl) { mutableStateOf(photoUrl?.let { MediaCache.image(it) }) }

    LaunchedEffect(photoUrl) {
        val key = photoUrl?.takeIf { it.isNotBlank() && !it.startsWith("http") } ?: return@LaunchedEffect
        if (bitmap != null) return@LaunchedEffect
        // Local-first: disk (off main thread) → only then network. A photo you uploaded or
        // saw once renders instantly and offline, no presigned re-download.
        withContext(Dispatchers.IO) { MediaCache.image(context, key) }?.let { bitmap = it; return@LaunchedEffect }
        runCatching {
            val bytes = MediaService(TokenStore.get(context)).download(key)
            MediaCache.putData(context, key, bytes)   // persist the plaintext bytes
            val bmp = withContext(Dispatchers.IO) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) } ?: return@runCatching
            val ib: ImageBitmap = bmp.asImageBitmap()
            MediaCache.putImage(key, ib)
            bitmap = ib
        }
    }

    val initials = (name ?: "").trim().split(" ").filter { it.isNotBlank() }
        .take(2).mapNotNull { it.firstOrNull() }.joinToString("").uppercase()

    Box(
        // When filling, the PARENT decides the frame and there is no circular clip or ring —
        // a hairline border around a full-bleed banner would read as a box drawn on the page.
        if (fillsFrame) {
            modifier.fillMaxSize().background(placeholderFill ?: VoiidColor.fieldFill)
        } else {
            modifier
                .size(size)
                .clip(CircleShape)
                .background(placeholderFill ?: VoiidColor.fieldFill)
                // The ring exists to separate the disc from what is behind it. When the
                // caller has matched the disc to its surface there is nothing to separate,
                // and the ring would be drawing a circle around nothing.
                .then(
                    if (placeholderFill != null) Modifier
                    else Modifier.border(1.dp, VoiidColor.divider.copy(alpha = 0.4f), CircleShape),
                )
        },
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

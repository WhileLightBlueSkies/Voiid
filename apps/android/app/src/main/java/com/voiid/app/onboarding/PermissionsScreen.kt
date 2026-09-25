package com.voiid.app.onboarding

import androidx.compose.material.icons.outlined.MicNone
import androidx.compose.material.icons.outlined.NearMe
import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import com.voiid.app.ui.components.pressableClickable
import com.voiid.app.ui.theme.VoiidSpacing
import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.LocationOn
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.Shield
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * Upfront permissions, built to the brand reference. Twin of iOS
 * `Onboarding/PermissionsScreen.swift` — the two must stay identical.
 *
 * Android can ask for several at once, so this is a single system prompt rather than iOS's
 * sequence. Best-effort either way: the user may deny any, and the flow continues regardless —
 * features re-ask in context where they need it.
 *
 * ── LOCATION IS LISTED BUT NOT REQUESTED HERE, AND THAT IS ON PURPOSE ────────────
 * The design lists Location as a sixth row, so it is shown: hiding it would misrepresent what
 * the app uses. But asking for location before the user has even signed in is the request most
 * likely to be denied, and on Android a second denial is permanent for the install. iOS carries
 * the same decision in MapLocationProvider's own doc comment — "never at onboarding".
 *
 * So the row explains what Location is for, and the Map asks when the user turns visibility on.
 * If the intent really is to prompt upfront, add ACCESS_COARSE_LOCATION to `permissions` and
 * delete this paragraph — but that reverses a deliberate call on both platforms, so it should be
 * a decision rather than a side effect.
 */
@Composable
fun PermissionsScreen(onContinue: () -> Unit, onBack: (() -> Unit)? = null) {
    val haptics = LocalVoiidHaptics.current
    var appeared by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { appeared = true }

    val permissions = buildList {
        add(Manifest.permission.READ_CONTACTS)
        // Same CONTACTS group as READ_CONTACTS, so this usually rides along in the one
        // prompt. It is what lets Voiid add the "Voice call (Voiid)" / "Video call (Voiid)"
        // rows to a contact's card. Refusing it costs those rows and nothing else — see
        // [com.voiid.app.contacts.VoiidContactsWriter], which checks before every write.
        add(Manifest.permission.WRITE_CONTACTS)
        add(Manifest.permission.CAMERA)
        add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(Manifest.permission.BLUETOOTH_CONNECT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.READ_MEDIA_IMAGES)
            add(Manifest.permission.READ_MEDIA_VIDEO)
            add(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            @Suppress("DEPRECATION")
            add(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        // Location deliberately absent — see the header note.
    }.toTypedArray()

    var requesting by remember { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { _ ->
        // Continue whatever the user chose.
        requesting = false
        haptics.success()
        onContinue()
    }

    OnboardingScaffold(
        onBack = onBack,
        footer = {
            OnboardingKitButton(title = "Allow All", enabled = !requesting, busy = requesting, usesBrandGradient = true) {
                requesting = true
                launcher.launch(permissions)
            }

            // THE DECLINE PATH. Android had none: the only way off this screen was to
            // trigger the system prompt. iOS's comment is blunt about why that is wrong —
            // "a priming screen that hides its decline is a dark pattern" — and the button
            // is not decoration, it calls onContinue directly and skips the ask entirely.
            Text(
                "Not now",
                style = VoiidFont.rounded(16),
                color = VoiidBrand.textDim,
                modifier = Modifier
                    .align(Alignment.CenterHorizontally)
                    .pressableClickable(enabled = !requesting) { haptics.tap(); onContinue() }
                    .padding(vertical = 6.dp),
            )
        },
    ) {
        Spacer(Modifier.height(VoiidSpacing.md))

        OnboardingHeader(
            title = OnboardingTitleSpec.Inline("Allow ", "Permissions"),
            blurb = "To give you the best experience, Voiid needs\na few permissions. You can " +
                "change these anytime\nin your device settings.",
        )

        OnboardingKitCard(Modifier.padding(top = VoiidSpacing.lg)) {
            val rows = permissionRows()
            rows.forEachIndexed { index, row ->
                OnboardingRow(
                    icon = row.glyph,
                    title = row.title,
                    subtitle = row.detail,
                    subtitleWraps = true,
                    // NO chevron and NO tap: these rows state what is being asked for. A
                    // chevron on a row that does nothing lies about what a tap does — and
                    // Android drew a lime arrow on every one of them.
                    showsChevron = false,
                )
                if (index < rows.size - 1) OnboardingRowDivider()
            }
        }

        Spacer(Modifier.height(VoiidSpacing.xl))
    }
}

private data class PermissionRow(
    val id: String,
    val glyph: ImageVector,
    val title: String,
    val detail: String,
)

/**
 * The six asks, in iOS's order and with iOS's copy.
 *
 * CONTACTS IS LAST, DELIBERATELY. It was first here, which inverted the reason iOS states
 * for the order: the most personal ask comes last, after the user has seen what the app
 * wants and why. Reordering it to the front makes the first thing Voiid ever asks for be
 * the address book.
 *
 * Every subtitle previously differed from iOS — all six — under a comment claiming they
 * matched word for word. They now actually do.
 */
private fun permissionRows(): List<PermissionRow> = listOf(
    // iOS uses the navigation arrow ("location"), not a pin.
    PermissionRow("location", Icons.Outlined.NearMe, "Location",
                  "Shows you relevant content and nearby features."),
    PermissionRow("notifications", Icons.Outlined.Notifications, "Notifications",
                  "Keeps you updated on activity and offers."),
    PermissionRow("camera", Icons.Outlined.CameraAlt, "Camera",
                  "Lets you capture and share moments."),
    PermissionRow("mic", Icons.Outlined.MicNone, "Microphone",
                  "Enables voice features and audio notes."),
    PermissionRow("photos", Icons.Outlined.Image, "Photos & Media",
                  "Lets you save, upload and share photos."),
    PermissionRow("contacts", Icons.Outlined.Person, "Contacts",
                  "Helps you find and connect with people you know (optional)."),
)

@Composable
private fun PermissionRowView(row: PermissionRow) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        OnboardingGlyphTile(row.glyph)

        Column(Modifier.weight(1f)) {
            Text(row.title, style = VoiidFont.rounded(17, FontWeight.SemiBold),
                 color = VoiidColor.textPrimary)
            Text(row.detail, style = VoiidFont.rounded(14),
                 color = VoiidColor.textSecondary)
        }

        // Points forward, not a chevron: these rows are not navigable — nothing opens. The
        // arrow reads as "this will be requested", which is what happens.
        Icon(
            Icons.Default.ArrowForward,
            contentDescription = null,
            tint = OnboardingBrand.lime,
            modifier = Modifier.size(18.dp),
        )
    }
}

package com.voiid.app.onboarding

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
fun PermissionsScreen(onContinue: () -> Unit) {
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

    Box(Modifier.fillMaxSize().background(OnboardingBrand.ground)) {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(20.dp))

            OnboardingBrandHeader(appeared = appeared)

            OnboardingTitle(accented = "Voiid", trailing = " needs a few permissions")
            Spacer(Modifier.height(6.dp))
            Text(
                "These permissions help us give you\nthe best experience.",
                style = VoiidFont.rounded(17),
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(22.dp))

            // Flush rows with hairline dividers rather than separate tiles — six tiles at this
            // size would fill the screen with gaps and the list would lose its shape.
            OnboardingCard(flush = true, modifier = Modifier.padding(horizontal = 20.dp)) {
                permissionRows().forEachIndexed { index, row ->
                    if (index > 0) {
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .height(1.dp)
                                .background(OnboardingBrand.hairline),
                        )
                    }
                    PermissionRowView(row)
                }
            }

            Spacer(Modifier.height(20.dp))

            OnboardingPrivacyNote(
                icon = Icons.Outlined.Shield,
                lines = listOf(
                    "We respect your privacy.",
                    "You can change these permissions anytime",
                    "in your device settings.",
                ),
                accentPhrase = "device settings",
                modifier = Modifier.padding(horizontal = 24.dp),
            )

            Spacer(Modifier.weight(1f))

            OnboardingPrimaryButton(
                title = "Allow Access",
                busy = requesting,
                modifier = Modifier.padding(horizontal = 20.dp),
            ) {
                requesting = true
                launcher.launch(permissions)
            }

            Spacer(Modifier.height(14.dp))
        }
    }
}

private data class PermissionRow(
    val id: String,
    val glyph: ImageVector,
    val title: String,
    val detail: String,
)

/**
 * Order matches the design: the two that find people and capture, then media, then the two
 * that reach out to the user. Copy matches iOS word for word — these screens are meant to be
 * indistinguishable.
 */
private fun permissionRows(): List<PermissionRow> = listOf(
    PermissionRow("contacts", Icons.Outlined.Person, "Contacts",
                  "Find and connect with your friends"),
    PermissionRow("camera", Icons.Outlined.CameraAlt, "Camera",
                  "Take photos and record videos"),
    PermissionRow("mic", Icons.Outlined.Mic, "Microphone",
                  "Make voice and video calls"),
    PermissionRow("photos", Icons.Outlined.Image, "Photos & Media",
                  "Share photos, videos and documents"),
    PermissionRow("notifications", Icons.Outlined.Notifications, "Notifications",
                  "Stay updated with important alerts"),
    PermissionRow("location", Icons.Outlined.LocationOn, "Location",
                  "Share your location and discover nearby"),
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

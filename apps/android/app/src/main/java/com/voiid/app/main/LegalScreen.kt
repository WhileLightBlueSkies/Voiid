package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.legal.ConsentPurpose
import com.voiid.app.legal.LegalDocument
import com.voiid.app.legal.LegalDocuments
import com.voiid.app.net.ConsentRecordInfo
import com.voiid.app.net.ConsentService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * Settings → Privacy & Legal. Twin of iOS `LegalView.swift`. Three jobs, in this order:
 *
 *  1. Say, in three lines and before anything else, what Voiid can and cannot see. Most
 *     people will never open the full notice; this screen is the version they read.
 *  2. Give the notice and the terms somewhere to be opened from, at any time and not only
 *     during sign-up.
 *  3. Show what you agreed to, and let you withdraw it in one tap.
 *
 * (3) is the load-bearing one. DPDP s.6(4) requires withdrawal to be as easy as giving, and
 * giving was a single tick on a single screen. A withdrawal that needs an email, a support
 * ticket or a hunt through three levels of settings does not meet that bar.
 *
 * Withdrawing deliberately does NOT delete the account here. Every purpose in the current
 * notice is one the service cannot run without, so withdrawal genuinely does mean the
 * account cannot continue — but destroying an account from a "withdraw" tap, with no
 * separate confirmation, would be a far worse surprise than the extra step. The dialog says
 * so plainly and points at the deletion screen.
 */
@Composable
fun LegalScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = LocalVoiidHaptics.current

    val status by ConsentService.status.collectAsState()
    var openDocument by remember { mutableStateOf<LegalDocument?>(null) }
    var confirmWithdraw by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var withdrew by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { ConsentService.refreshStatus(context) }

    // The live consent matching the version this build renders. A record against some other
    // version is not shown as "your consent" here, because the words on this screen would
    // not be the words that record refers to.
    val live: ConsentRecordInfo? = status?.consents
        ?.firstOrNull { it.notice_version == LegalDocuments.NOTICE_VERSION }
        ?: status?.consents?.firstOrNull()

    val document = openDocument
    if (document != null) {
        LegalDocumentScreen(document = document, onBack = { openDocument = null })
        return
    }

    BackupScaffold(title = "Privacy & Legal", onBack = onBack) {
        Spacer(Modifier.height(8.dp))

        // ── In short ──────────────────────────────────────────────────────────────
        // Written to be read by someone who will not open the notice — which is most
        // people — so it leads with the limit rather than the reassurance.
        SectionHeader("In short")
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Claim(
                Icons.Default.Lock, VoiidColor.success,
                "Voiid cannot read what you send",
                "Messages, calls, live location and moments are encrypted on your device and decrypted on the other person's. The server holds the encrypted bytes and no key.",
            )
            Claim(
                Icons.Default.Visibility, VoiidColor.warning,
                "Voiid can see who and when",
                "Your phone number, which account a message is addressed to and when it arrived, your device type and app version, and the IP address you connect from.",
            )
            Claim(
                Icons.Default.Block, VoiidColor.textSecondary,
                "Voiid does not sell or profile you",
                "No advertising identifiers, no behavioural tracking, no background location.",
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(
            "Clips are the exception: a Clip is a public post, stored unencrypted, and Voiid's moderators can see and remove it.",
            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
        )

        // ── Documents ─────────────────────────────────────────────────────────────
        Spacer(Modifier.height(20.dp))
        SectionHeader("Documents")
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard),
        ) {
            LegalDocuments.all.forEachIndexed { index, doc ->
                if (index > 0) LegalDivider()
                Row(
                    Modifier.fillMaxWidth().height(52.dp)
                        .softClickable { haptics.tap(); openDocument = doc }
                        .padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(doc.title, style = VoiidFont.rounded(15),
                        color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null,
                        tint = VoiidColor.textSecondary, modifier = Modifier.size(20.dp))
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(
            "Version ${LegalDocuments.NOTICE_VERSION}. Stored in the app, so they open without a connection.",
            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
        )

        // ── Your consent ──────────────────────────────────────────────────────────
        Spacer(Modifier.height(20.dp))
        SectionHeader("Your consent")
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            when {
                live != null -> {
                    KeyValue("Agreed on", shortDate(live.given_at))
                    KeyValue("Notice version", live.notice_version ?: "—")
                    LegalDocuments.purposes.forEach { purpose ->
                        PurposeRow(purpose, granted = live.purposes?.get(purpose.id) == true)
                    }
                }
                withdrew -> Text("Consent withdrawn.",
                    style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
                else -> Text("No consent on record for this account.",
                    style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(
            if (live != null) {
                "You can withdraw this at any time, in one tap. Withdrawing does not delete your account — Delete My Account, in Edit Profile, does that."
            } else {
                "Voiid asks for consent before it processes your phone number. If nothing is recorded here, you will be asked on next launch."
            },
            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
        )

        if (live != null) {
            Spacer(Modifier.height(20.dp))
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.surfaceCard),
            ) {
                Row(
                    Modifier.fillMaxWidth().height(52.dp)
                        .softClickable(enabled = !working) { haptics.tap(); confirmWithdraw = true }
                        .padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        if (working) "Withdrawing…" else "Withdraw consent",
                        style = VoiidFont.rounded(15), color = VoiidColor.error,
                    )
                }
            }
        }

        errorText?.let {
            Spacer(Modifier.height(12.dp))
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
        }
        Spacer(Modifier.height(24.dp))
    }

    if (confirmWithdraw) {
        AlertDialog(
            onDismissRequest = { confirmWithdraw = false },
            title = { Text("Withdraw consent?", style = VoiidFont.rounded(17, FontWeight.SemiBold)) },
            text = {
                Text(
                    "Voiid needs your phone number to run your account and needs to know where to " +
                        "deliver messages, so it cannot keep working without this consent. Withdrawing " +
                        "records that you have withdrawn it — it does not delete your account. To have " +
                        "your data erased, use Delete My Account in Edit Profile.",
                    style = VoiidFont.rounded(14),
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmWithdraw = false
                    scope.launch {
                        working = true
                        errorText = try {
                            ConsentService.withdraw(context)
                            withdrew = true
                            haptics.tap()
                            null
                        } catch (e: Exception) {
                            e.message ?: "Couldn't update consent."
                        }
                        working = false
                    }
                }) { Text("Withdraw", color = VoiidColor.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmWithdraw = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(text, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary)
    Spacer(Modifier.height(8.dp))
}

@Composable
private fun Claim(icon: ImageVector, tint: Color, title: String, detail: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(12.dp))
        Column {
            Text(title, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
            Spacer(Modifier.height(2.dp))
            Text(detail, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        }
    }
}

@Composable
private fun KeyValue(title: String, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary,
            modifier = Modifier.weight(1f))
        Text(value, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
    }
}

@Composable
private fun PurposeRow(purpose: ConsentPurpose, granted: Boolean) {
    Row(verticalAlignment = Alignment.Top) {
        Column(Modifier.weight(1f)) {
            Text(purpose.title, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
            Spacer(Modifier.height(2.dp))
            Text(purpose.detail, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        }
        Spacer(Modifier.width(12.dp))
        Icon(
            if (granted) Icons.Default.Check else Icons.Default.Close,
            contentDescription = if (granted) "Agreed" else "Not agreed",
            tint = if (granted) VoiidColor.success else VoiidColor.textSecondary,
            modifier = Modifier.size(18.dp),
        )
    }
}

/** This file's own hairline. `SettingsScreen.SettingsDivider` is private to that file, and
 *  a second import-only copy there would be worse than eight lines here. */
@Composable
private fun LegalDivider() {
    Spacer(
        Modifier.fillMaxWidth().height(1.dp)
            .padding(start = 16.dp)
            .background(VoiidColor.divider),
    )
}

/**
 * ISO-8601 from Postgres ("2026-08-06T02:51:25.270Z"), rendered as a plain date.
 *
 * Deliberately string slicing rather than `java.time`: minSdk is 24, core-library
 * desugaring is not enabled in this module, and `OffsetDateTime` does not exist below API
 * 26. The existing `java.time` call sites in net/ survive only because they sit inside
 * `runCatching` and silently return null on those devices — a date on a consent screen
 * turning into "—" for every Android 7 user is not a trade worth making for prettier
 * formatting. Falls back to the raw string, because an unparseable date is a bug worth
 * seeing rather than one worth hiding.
 */
private fun shortDate(iso: String?): String {
    if (iso.isNullOrBlank()) return "—"
    val date = iso.substringBefore('T')
    val parts = date.split("-")
    if (parts.size != 3) return iso
    val months = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun",
                        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    val month = parts[1].toIntOrNull()?.takeIf { it in 1..12 } ?: return iso
    val day = parts[2].toIntOrNull() ?: return iso
    return "$day ${months[month - 1]} ${parts[0]}"
}

package com.voiid.app.onboarding

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Lock
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.voiid.app.legal.LegalDocument
import com.voiid.app.legal.LegalDocuments
import com.voiid.app.main.LegalDocumentScreen
import com.voiid.app.net.ConsentService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * Onboarding step 1 — the first screen a new user ever sees. Twin of iOS
 * `Onboarding/WelcomeTermsScreen.swift`; the two must stay identical.
 *
 * ── THIS SCREEN IS THE CONSENT MOMENT, NOT JUST A SPLASH ─────────────────────────
 * DPDP s.5 wants notice "at or before" processing, so the affirmative action happens HERE —
 * before a phone number, before an OTP, before a JWT exists. There is no account to attach
 * consent to yet, which is the sequencing problem ConsentService solves: the record is written
 * LOCALLY and posted once an account exists.
 *
 * CONSENT IS NOW RECORDED ON THE BUTTON, not on a tick. The old screen recorded it the moment a
 * checkbox was ticked, which was right for that design — a tick IS the affirmative act. This
 * design has no checkbox: the single button is the act, so that is where the record is written.
 *
 * ── WHY THE ROWS ARE NOT CHECKBOXES ──────────────────────────────────────────────
 * Every purpose in this version is required, so a box the user cannot untick misrepresents the
 * choice on offer. The rows show what is being agreed to and each opens the real document; the
 * button is the consent. The check marks are state — "this is included" — not controls.
 */
@Composable
fun WelcomeTermsScreen(
    onContinue: () -> Unit,
    /** Someone returning on a new device skips the funnel. They still consent: the notice was
     *  shown, and an existing user has the same DPDP footing as a new one. */
    onExistingAccount: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    var appeared by remember { mutableStateOf(false) }
    /** Rendered IN PLACE of this screen rather than over it: the onboarding host is a single
     *  AnimatedContent with no dialog layer, and a legal document is a full read, not a peek. */
    var openDocument by remember { mutableStateOf<LegalDocument?>(null) }

    LaunchedEffect(Unit) { appeared = true }

    val document = openDocument
    if (document != null) {
        LegalDocumentScreen(document = document, onBack = { openDocument = null })
        return
    }

    fun recordConsent() {
        ConsentService.recordLocalConsent(
            context = context,
            purposes = LegalDocuments.purposes.associate { it.id to true },
        )
    }

    Box(
        Modifier
            .fillMaxSize()
            // Committed to dark — see the note in OnboardingBrandChrome on why these screens
            // ignore the theme override.
            .background(OnboardingBrand.ground),
    ) {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // SCROLLS, and it has to. The fixed content — header, title, a four-row card, the
            // privacy note, the button and two footnotes — is around 900dp, which overflows
            // every phone but the largest. A weight(1f) spacer cannot fix an overflow: it has
            // nothing to give, so the first version crushed the card and pushed the button off
            // the bottom edge.
            //
            // The button stays PINNED outside the scroll: the primary action must never require
            // scrolling to reach, which is the whole reason it is the brightest thing here.
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.height(8.dp))

                OnboardingBrandHeader(appeared = appeared)

                OnboardingTitle(leading = "Welcome to ", accented = "Voiid")
                Spacer(Modifier.height(6.dp))
                Text(
                "One app. Everything you need.",
                style = VoiidFont.rounded(17),
                color = VoiidColor.textSecondary,
                )

                Spacer(Modifier.height(26.dp))

                OnboardingCard(modifier = Modifier.padding(horizontal = 20.dp)) {
                Text(
                    "Let's get you started.",
                    style = VoiidFont.rounded(20, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    "Please review and accept the following to continue.",
                    style = VoiidFont.rounded(15),
                    color = VoiidColor.textSecondary,
                )
                Spacer(Modifier.height(18.dp))

                consentRows().forEach { row ->
                    ConsentRowView(row) { haptics.tap(); openDocument = row.document }
                    Spacer(Modifier.height(10.dp))
                }
                }

                Spacer(Modifier.height(22.dp))

                OnboardingPrivacyNote(
                icon = Icons.Outlined.Lock,
                lines = listOf(
                    "Your privacy is our priority.",
                    "All communications are end-to-end encrypted.",
                ),
                accentPhrase = "end-to-end encrypted",
                modifier = Modifier.padding(horizontal = 24.dp),
                )

                Spacer(Modifier.height(18.dp))
            }

            OnboardingPrimaryButton(
                title = "I Agree & Continue",
                modifier = Modifier.padding(horizontal = 20.dp),
            ) {
                recordConsent()
                onContinue()
            }

            if (onExistingAccount != null) {
                Spacer(Modifier.height(14.dp))
                Text(
                    "I already have an account",
                    style = VoiidFont.rounded(14),
                    color = VoiidColor.textSecondary,
                    modifier = Modifier.softClickable {
                        haptics.tap(); recordConsent(); onExistingAccount()
                    },
                )
            }

            Spacer(Modifier.height(10.dp))
            Text(
                buildString(context),
                style = VoiidFont.rounded(12),
                color = VoiidColor.textSecondary.copy(alpha = 0.7f),
            )
            Spacer(Modifier.height(10.dp))
        }
    }
}

/** Version + build from the package manager, rather than a literal someone must remember to bump. */
private fun buildString(context: android.content.Context): String = runCatching {
    val pm = context.packageManager.getPackageInfo(context.packageName, 0)
    @Suppress("DEPRECATION")
    "v${pm.versionName} (${pm.versionCode})"
}.getOrDefault("")

private data class ConsentRow(
    val id: String,
    val title: String,
    val subtitle: String,
    val document: LegalDocument,
    val glyph: androidx.compose.ui.graphics.vector.ImageVector? = null,
    val ageBadge: Boolean = false,
)

/**
 * The four things being agreed to. Order matches the design and reads terms → privacy → data
 * → age: what the deal is, then what happens to your data, then who you say you are.
 */
private fun consentRows(): List<ConsentRow> = listOf(
    ConsentRow("terms", "Terms of Service", "Read our Terms of Service",
               LegalDocuments.terms, glyph = Icons.Outlined.Shield),
    ConsentRow("privacy", "Privacy Policy", "Read our Privacy Policy",
               LegalDocuments.privacy, glyph = Icons.Outlined.Lock),
    ConsentRow("data", "Data Protection", "Read about how we protect your data",
               LegalDocuments.privacy, glyph = Icons.Outlined.Person),
    ConsentRow("age", "Age Confirmation", "I confirm that I am 14 years or older",
               LegalDocuments.terms, ageBadge = true),
)

@Composable
private fun ConsentRowView(row: ConsentRow, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(OnboardingBrand.row)
            .border(1.dp, OnboardingBrand.hairline, RoundedCornerShape(16.dp))
            .softClickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        if (row.ageBadge) {
            // "14+" in a ring. No icon set carries an age, and drawing it keeps the number
            // honest — if the threshold changes the label changes with it, rather than an icon
            // name quietly lying.
            Box(
                Modifier
                    .size(38.dp)
                    .border(1.5.dp, OnboardingBrand.lime, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Text("14+", style = VoiidFont.rounded(12, FontWeight.Bold),
                     color = OnboardingBrand.lime)
            }
        } else if (row.glyph != null) {
            OnboardingGlyphTile(row.glyph, size = 38.dp)
        }

        Column(Modifier.weight(1f)) {
            Text(row.title, style = VoiidFont.rounded(16, FontWeight.SemiBold),
                 color = VoiidColor.textPrimary)
            Text(row.subtitle, style = VoiidFont.rounded(14),
                 color = VoiidColor.textSecondary)
        }

        // STATE, not a control — see the header note on why these are not checkboxes.
        Icon(
            Icons.Default.CheckCircle,
            contentDescription = null,
            tint = OnboardingBrand.lime,
            modifier = Modifier.size(24.dp),
        )
    }
}

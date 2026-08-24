package com.voiid.app.onboarding

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.Spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.CreditCard
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.GppGood
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.PanTool
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.voiid.app.legal.LegalDocument
import com.voiid.app.legal.LegalDocuments
import com.voiid.app.main.LegalDocumentBody
import com.voiid.app.net.ConsentService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidDetent
import com.voiid.app.ui.components.VoiidSheet
import com.voiid.app.ui.components.reduceMotionEnabled
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.LocalVoiidDark
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * Onboarding step 1 — the first screen a new user ever sees. Twin of iOS
 * `Onboarding/WelcomeTermsScreen.swift`; the two must stay identical.
 *
 * ── THE CONSENT MOMENT ───────────────────────────────────────────────────────────
 * DPDP s.5 wants notice "at or before" processing, so the affirmative action happens HERE —
 * before a phone number, before an OTP, before a JWT exists. There is no account to attach
 * consent to yet, so the record is written LOCALLY (ConsentService) and posted once an account
 * exists.
 *
 * CONSENT IS THE CHECKBOX, not the button: an explicit 26dp tick gates a disabled Continue,
 * so nobody can agree by accident and nobody can continue without agreeing. Mirrors iOS.
 *
 * The document rows are READ affordances — each opens its legal document in a sheet. Several
 * rows share one underlying document until the rest are written, exactly as on iOS.
 */
@Composable
fun WelcomeTermsScreen(
    onContinue: () -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val reduceMotion = reduceMotionEnabled()
    var appeared by remember { mutableStateOf(false) }
    var accepted by remember { mutableStateOf(false) }
    /** The document to render inside the sheet; non-null while the sheet flow is live. */
    var openDocument by remember { mutableStateOf<LegalDocument?>(null) }
    var sheetVisible by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { appeared = true }

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
            // SCROLLS, because the fixed content overflows every phone but the largest. The
            // footer below is PINNED outside it: the consent control must never require
            // scrolling to reach.
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.height(8.dp))

                OnboardingBrandHeader(appeared = appeared)

                OnboardingTitle(leading = "Terms & ", accented = "Conditions")
                Spacer(Modifier.height(6.dp))
                Text(
                    "Please read these important documents carefully.\nBy continuing, you agree to our policies.",
                    style = VoiidFont.rounded(15),
                    color = VoiidColor.textSecondary,
                    modifier = Modifier.padding(horizontal = 24.dp),
                )

                Spacer(Modifier.height(24.dp))

                // ALPHABETICAL BY TITLE, ascending — six items are past the point where a
                // reader scans the whole list, so a predictable order lets them find one by
                // name. Terms of Service and Privacy Policy sit last while the checkbox names
                // exactly those two — which is why both are also linked in the consent line.
                OnboardingCard(flush = true, modifier = Modifier.padding(horizontal = 20.dp)) {
                    documentRows().forEachIndexed { index, row ->
                        DocumentRowView(row) {
                            haptics.tap()
                            openDocument = row.document
                            sheetVisible = true
                        }
                        if (index < documentRows().size - 1) DocumentRowDivider()
                    }
                }

                Spacer(Modifier.height(22.dp))

                OnboardingPrivacyNote(
                    icon = Icons.Outlined.Shield,
                    lines = listOf(
                        "Your privacy and security are our top priority.",
                        "We never sell your personal data.",
                    ),
                    accentPhrase = null,
                    modifier = Modifier.padding(horizontal = 24.dp),
                )

                Spacer(Modifier.height(18.dp))
            }

            // PINNED footer: the explicit consent control + the gated primary action.
            ConsentRow(
                accepted = accepted,
                reduceMotion = reduceMotion,
                onToggle = {
                    haptics.selection()
                    accepted = it
                },
                modifier = Modifier.padding(horizontal = 24.dp),
            )
            Spacer(Modifier.height(14.dp))
            OnboardingPrimaryButton(
                title = "Continue",
                enabled = accepted,
                modifier = Modifier.padding(horizontal = 20.dp),
            ) {
                recordConsent()
                onContinue()
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

    // Legal documents present in a SHEET over this screen — committed dark to match the
    // onboarding visual system. Dismissal is async-safe: the doc state clears only after the
    // exit finishes, so there is no flash of an empty sheet.
    CompositionLocalDarkOnboarding {
        VoiidSheet(
            visible = sheetVisible,
            onDismiss = { openDocument = null },
            detents = listOf(VoiidDetent.Medium, VoiidDetent.Large),
            initialDetentIndex = 0,
        ) {
            val doc = openDocument ?: return@VoiidSheet
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    doc.title,
                    style = VoiidFont.rounded(17, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    "Done",
                    style = VoiidFont.rounded(15, FontWeight.Medium),
                    color = VoiidColor.primary,
                    modifier = Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) { haptics.tap(); sheetVisible = false },
                )
            }
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp),
            ) {
                LegalDocumentBody(doc)
            }
        }
    }
}

/** Forces the committed-dark token resolution inside the sheet. */
@Composable
private fun CompositionLocalDarkOnboarding(content: @Composable () -> Unit) =
    androidx.compose.runtime.CompositionLocalProvider(LocalVoiidDark provides true) { content() }

// MARK: - Documents

private data class DocumentRow(
    val id: String,
    val title: String,
    val subtitle: String,
    val document: LegalDocument,
    val glyph: ImageVector,
)

/**
 * The six things a new user can read, mapped onto the bundled documents. Order and copy mirror
 * iOS `WelcomeTermsScreen.rows`; several rows share one document until the remaining legal text
 * is written (identical to iOS).
 */
private fun documentRows(): List<DocumentRow> = listOf(
    DocumentRow("additional", "Additional Information", "Disclaimers and other legal information.", LegalDocuments.terms, Icons.Outlined.Info),
    DocumentRow("community", "Community Guidelines", "Standards for a safe and respectful community.", LegalDocuments.terms, Icons.Outlined.Group),
    DocumentRow("data", "Data Protection", "Your data rights and security information.", LegalDocuments.privacy, Icons.Outlined.GppGood),
    DocumentRow("payments", "Payments Terms", "Important information about payments.", LegalDocuments.terms, Icons.Outlined.CreditCard),
    DocumentRow("privacy", "Privacy Policy", "How we collect, use and protect your data.", LegalDocuments.privacy, Icons.Outlined.PanTool),
    DocumentRow("tos", "Terms of Service", "Rules for using Voiid and our services.", LegalDocuments.terms, Icons.Outlined.Description),
)

/** A tappable document row — a read affordance, so the disclosure chevron, not a checkmark. */
@Composable
private fun DocumentRowView(row: DocumentRow, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .softClickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        OnboardingGlyphTile(row.glyph, size = 38.dp)
        Column(Modifier.weight(1f)) {
            Text(row.title, style = VoiidFont.rounded(16, FontWeight.SemiBold),
                 color = VoiidColor.textPrimary)
            Text(row.subtitle, style = VoiidFont.rounded(14),
                 color = VoiidColor.textSecondary)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = VoiidColor.textSecondary,
            modifier = Modifier.size(22.dp),
        )
    }
}

@Composable
private fun DocumentRowDivider() {
    Box(
        Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(OnboardingBrand.hairline),
    )
}

// MARK: - Consent

/**
 * The consent control. The WHOLE ROW is the hit target — a 26dp checkbox alone is well under
 * the minimum touch size and this is the single most important control on the screen.
 */
@Composable
private fun ConsentRow(
    accepted: Boolean,
    reduceMotion: Boolean,
    onToggle: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .clip(RoundedCornerShape(12.dp))
            .softClickable { onToggle(!accepted) }
            .padding(vertical = 10.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CheckboxMark(accepted, reduceMotion)
        Text(
            buildAnnotatedString {
                append("I have read and agree to the ")
                withStyle(SpanStyle(color = OnboardingBrand.lime)) { append("Terms of Service") }
                append(" and ")
                withStyle(SpanStyle(color = OnboardingBrand.lime)) { append("Privacy Policy") }
                append(".")
            },
            style = VoiidFont.rounded(15),
            color = VoiidColor.textPrimary,
        )
    }
}

/**
 * 26dp box, 8dp radius, 2dp stroke — filled lime with a white tick when agreed. The tick scales
 * in from 0.6 rather than appearing: it confirms a deliberate choice, so it should feel like it
 * landed. Values are the iOS ones exactly.
 */
@Composable
private fun CheckboxMark(accepted: Boolean, reduceMotion: Boolean) {
    val shape = RoundedCornerShape(8.dp)
    val tickScale by animateFloatAsState(
        targetValue = if (accepted || reduceMotion) 1f else 0.6f,
        animationSpec = spring(dampingRatio = 0.9f, stiffness = Spring.StiffnessMediumLow),
        label = "consentTickScale",
    )
    val tickAlpha by animateFloatAsState(
        targetValue = if (accepted) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.9f, stiffness = Spring.StiffnessMediumLow),
        label = "consentTickAlpha",
    )
    Box(
        Modifier
            .size(26.dp)
            .border(2.dp, if (accepted) OnboardingBrand.lime else VoiidColor.fieldBorder, shape)
            .background(if (accepted) OnboardingBrand.lime else androidx.compose.ui.graphics.Color.Transparent, shape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Default.Check,
            contentDescription = if (accepted) "Agreed" else "Not agreed",
            tint = androidx.compose.ui.graphics.Color.White,
            modifier = Modifier.size(15.dp).scale(tickScale).alpha(tickAlpha),
        )
    }
}

/** Version + build from the package manager, rather than a literal someone must remember to bump. */
private fun buildString(context: android.content.Context): String = runCatching {
    val pm = context.packageManager.getPackageInfo(context.packageName, 0)
    @Suppress("DEPRECATION")
    "v${pm.versionName} (${pm.versionCode})"
}.getOrDefault("")

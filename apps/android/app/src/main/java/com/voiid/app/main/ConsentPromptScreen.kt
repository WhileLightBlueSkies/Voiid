package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.legal.LegalDocument
import com.voiid.app.legal.LegalDocuments
import com.voiid.app.net.ConsentService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * The backfill prompt: consent capture for accounts that already exist. Twin of iOS
 * `ConsentPromptView.swift`.
 *
 * Every account created before this change has no consent record, because the endpoint that
 * would have written one was never called by any client. Those users cannot be retro-fitted
 * by a migration — a row written on their behalf would be a FABRICATED consent record,
 * which is worse than none — so they are asked, once, on next launch.
 *
 * IT MUST BE REFUSABLE. DPDP s.6 requires consent to be free and unconditional, so "Not
 * now" is a real answer: it dismisses for this launch and the prompt returns next time. A
 * modal that cannot be dismissed until you agree is coercion with a checkbox, and the
 * consent it collects is worth nothing. What it is NOT is "never ask again" — refusing does
 * not silently grant permission to keep processing quietly.
 *
 * [COUNSEL] What Voiid must do about an existing account whose user keeps declining is
 * unresolved: continuing to process indefinitely on the strength of an old sign-up is not
 * obviously lawful, and suspending the account of someone who has simply not read a modal
 * is not obviously proportionate. Do not resolve this by adding a deadline here.
 */
@Composable
fun ConsentPromptScreen(onDefer: () -> Unit, onAccepted: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = LocalVoiidHaptics.current

    var openDocument by remember { mutableStateOf<LegalDocument?>(null) }
    var working by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    val document = openDocument
    if (document != null) {
        LegalDocumentScreen(document = document, onBack = { openDocument = null })
        return
    }

    Column(
        Modifier.fillMaxSize().background(VoiidColor.background)
            .statusBarsPadding().navigationBarsPadding(),
    ) {
        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp).padding(top = 24.dp, bottom = 16.dp),
        ) {
            Text(
                "Before you carry on",
                style = VoiidFont.rounded(28, FontWeight.Bold),
                color = VoiidColor.textPrimary,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                "Voiid now asks for your consent before it processes your account data, and lets " +
                    "you take that consent back at any time. Your account was created before we " +
                    "did this, so we are asking you once now.",
                style = VoiidFont.rounded(15),
                color = VoiidColor.textSecondary,
            )

            Spacer(Modifier.height(20.dp))
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.surfaceCard).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                LegalDocuments.purposes.forEach { purpose ->
                    Column {
                        Text(purpose.title, style = VoiidFont.rounded(15, FontWeight.Medium),
                            color = VoiidColor.textPrimary)
                        Spacer(Modifier.height(2.dp))
                        Text(purpose.detail, style = VoiidFont.rounded(13),
                            color = VoiidColor.textSecondary)
                    }
                }
            }

            // The documents, ABOVE the button. A consent flow where the button sits above
            // the thing being consented to is a dark pattern with good intentions.
            Spacer(Modifier.height(20.dp))
            LegalDocuments.all.forEach { doc ->
                Row(
                    Modifier.fillMaxWidth().height(44.dp)
                        .softClickable { haptics.tap(); openDocument = doc },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(doc.title, style = VoiidFont.rounded(15, FontWeight.Medium),
                        color = VoiidColor.primary)
                    Spacer(Modifier.width(4.dp))
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null,
                        tint = VoiidColor.primary, modifier = Modifier.size(18.dp))
                }
            }

            Spacer(Modifier.height(16.dp))
            Text(
                "Voiid still cannot read your messages, calls, live location or moments. That does " +
                    "not change, and this consent does not give it that ability.",
                style = VoiidFont.rounded(12),
                color = VoiidColor.textSecondary,
            )

            errorText?.let {
                Spacer(Modifier.height(12.dp))
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            }
        }

        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            BackupButton(title = if (working) "Saving…" else "I Agree", enabled = !working) {
                scope.launch {
                    working = true
                    errorText = try {
                        ConsentService.submitConsent(
                            context = context,
                            purposes = LegalDocuments.purposes.associate { it.id to true },
                            givenVia = "backfill_prompt",
                        )
                        haptics.tap()
                        onAccepted()
                        null
                    } catch (e: Exception) {
                        e.message ?: "Couldn't record consent."
                    }
                    working = false
                }
            }
            TextButton(onClick = onDefer, enabled = !working) {
                Text("Not now", style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
            }
        }
    }
}

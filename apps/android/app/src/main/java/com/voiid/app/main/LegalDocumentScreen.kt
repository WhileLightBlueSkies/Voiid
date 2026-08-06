package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.legal.LegalDocument
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * Renders a [LegalDocument]. Twin of iOS `LegalDocumentView.swift`.
 *
 * Native text, not a WebView pointed at a URL, for the reason the document model's header
 * gives: the notice must be readable on the first screen of onboarding, offline, before an
 * account exists.
 */
@Composable
fun LegalDocumentScreen(document: LegalDocument, onBack: () -> Unit) {
    BackupScaffold(title = document.title, onBack = onBack) {
        Spacer(Modifier.height(4.dp))

        // The version is not decoration: consent is recorded against this exact string, so
        // the screen has to show which string it is showing.
        Text(
            "Version ${document.version} · Effective ${document.effectiveDate}",
            style = VoiidFont.rounded(12),
            color = VoiidColor.textSecondary,
        )
        Spacer(Modifier.height(16.dp))

        Text(
            document.summary,
            style = VoiidFont.rounded(16, FontWeight.Medium),
            color = VoiidColor.textPrimary,
        )

        document.sections.forEach { section ->
            Spacer(Modifier.height(24.dp))
            Text(
                section.heading,
                style = VoiidFont.rounded(18, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
            )
            section.body.forEach { para ->
                Spacer(Modifier.height(8.dp))
                Paragraph(para)
            }
        }

        if (document.pendingCounselOrBuild.isNotEmpty()) {
            Spacer(Modifier.height(28.dp))
            PendingBlock(document.pendingCounselOrBuild)
        }
        Spacer(Modifier.height(24.dp))
    }
}

/** A bullet keeps its marker but gets a hanging indent, so wrapped lines line up under the
 *  text rather than under the dot. */
@Composable
private fun Paragraph(text: String) {
    if (text.startsWith("• ")) {
        Row(Modifier.fillMaxWidth().padding(start = 8.dp), horizontalArrangement = Arrangement.Start) {
            Text("•", style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
            Spacer(Modifier.width(8.dp))
            Text(
                text.removePrefix("• "),
                style = VoiidFont.rounded(15),
                color = VoiidColor.textSecondary,
            )
        }
    } else {
        Text(text, style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
    }
}

/**
 * The unfinished list, rendered rather than hidden.
 *
 * Shipping a legal document with holes in it is bad. Shipping one with the holes papered
 * over by text an engineer invented is worse, and it is the specific failure this whole
 * change exists to avoid — so the holes are on screen, named, in a block that is visually
 * distinct from the notice itself. When counsel supplies the real answers the list empties
 * and this block disappears on its own.
 */
@Composable
private fun PendingBlock(lines: List<String>) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.warning.copy(alpha = 0.4f), RoundedCornerShape(VoiidRadius.md))
            .padding(16.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Default.Warning, null, tint = VoiidColor.warning, modifier = Modifier.width(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(
                "Still being finalised",
                style = VoiidFont.rounded(15, FontWeight.SemiBold),
                color = VoiidColor.warning,
            )
        }
        lines.forEach { line ->
            Spacer(Modifier.height(8.dp))
            Paragraph(line)
        }
    }
}

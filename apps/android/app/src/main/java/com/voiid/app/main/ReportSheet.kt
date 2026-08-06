package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.ReportService
import com.voiid.app.net.ReportTarget
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * Reporting a clip, a creator, or a person. Port of iOS `ReportSheet.swift`.
 *
 * ── WHAT THIS SENDS ──────────────────────────────────────────────────────────────
 * A reason and, optionally, the reporter's own words. NOTHING ELSE. Reporting a person is
 * a report about THEM, not about a message: there is no message id in the payload and no
 * way to attach one, because the server has no key and "fetch the reported message" is a
 * feature that must stay unbuildable.
 *
 * The sheet says so on screen rather than letting the user assume either way. Someone
 * reporting harassment deserves to know whether a moderator will be able to read what was
 * said, and the honest answer is no.
 */
@Composable
fun ReportSheet(target: ReportTarget, onDone: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val svc = remember { ReportService(context) }

    var reason by remember { mutableStateOf("spam") }
    var note by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var sent by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    // Mirrors the server vocabulary exactly (035_reports.sql). Data rather than a when-block
    // so the two cannot drift into a client offering a reason the server rejects.
    val reasons = listOf(
        "spam" to "Spam",
        "harassment" to "Harassment or bullying",
        "hate" to "Hate speech",
        "violence" to "Violence",
        "nudity" to "Nudity or sexual content",
        "self_harm" to "Self-harm",
        "child_safety" to "Child safety",
        "impersonation" to "Impersonation",
        "illegal" to "Something illegal",
        "other" to "Something else",
    )

    Column(
        Modifier.fillMaxWidth()
            .background(VoiidColor.surfaceCard, RoundedCornerShape(VoiidRadius.lg))
            .padding(20.dp)
            .verticalScroll(rememberScrollState()),
    ) {
        if (sent) {
            Text("Thanks — this has been sent to our moderators.",
                style = VoiidFont.rounded(16), color = VoiidColor.textPrimary)
            Spacer(Modifier.height(16.dp))
            Text("Done", style = VoiidFont.rounded(15, FontWeight.SemiBold),
                color = VoiidColor.primary, modifier = Modifier.softClickable(onClick = onDone))
            return@Column
        }

        Text("Report", style = VoiidFont.rounded(18, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Spacer(Modifier.height(4.dp))
        Text("Why are you reporting this?",
            style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        Spacer(Modifier.height(12.dp))

        reasons.forEach { (value, label) ->
            Row(
                Modifier.fillMaxWidth().softClickable { haptics.tap(); reason = value }
                    .padding(vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(label, style = VoiidFont.rounded(15),
                    color = VoiidColor.textPrimary, modifier = Modifier.weight(1f))
                if (reason == value) {
                    Icon(Icons.Default.Check, null, tint = VoiidColor.primary,
                        modifier = Modifier.size(18.dp))
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        BasicTextField(
            value = note, onValueChange = { note = it },
            textStyle = TextStyle(color = VoiidColor.textPrimary),
            modifier = Modifier.fillMaxWidth().heightIn(min = 72.dp)
                .clip(RoundedCornerShape(VoiidRadius.md)).background(VoiidColor.fieldFill)
                .padding(12.dp),
            decorationBox = { inner ->
                if (note.isEmpty()) {
                    Text("Anything you want to add (optional)",
                        style = VoiidFont.rounded(14), color = VoiidColor.placeholder)
                }
                inner()
            },
        )

        Spacer(Modifier.height(10.dp))
        // The one sentence that matters most on this screen.
        Text(
            if (target is ReportTarget.Person)
                "We can see who you are reporting and what you write here. We cannot read "
                    + "your messages with them — those are encrypted and we hold no key."
            else "We can see the content you are reporting.",
            style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
        )

        error?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
        }

        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            Text("Cancel", style = VoiidFont.rounded(15),
                color = VoiidColor.textSecondary,
                modifier = Modifier.softClickable(onClick = onDone))
            Text(if (busy) "Sending…" else "Send",
                style = VoiidFont.rounded(15, FontWeight.SemiBold),
                color = VoiidColor.primary,
                modifier = Modifier.softClickable {
                    if (busy) return@softClickable
                    haptics.tap(); busy = true; error = null
                    scope.launch {
                        runCatching { svc.submit(target, reason, note.trim()) }
                            .onSuccess { sent = true }
                            .onFailure { error = it.message ?: "Couldn't send that report." }
                        busy = false
                    }
                })
        }
    }
}

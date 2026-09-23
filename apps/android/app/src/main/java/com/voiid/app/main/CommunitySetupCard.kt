package com.voiid.app.main

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.FormatAlignLeft
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.PersonAdd
import androidx.compose.material.icons.outlined.Rule
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.CommunityService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidDialog
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

/**
 * "Finish setting up" — what the two-step create flow deliberately did not ask. Port of iOS
 * `CommunitySetupCard`; the two must tick the same tasks for the same community.
 *
 * DERIVED FROM THE SERVER, NOT REMEMBERED: a task is done when the community says so — a
 * description exists, a Space beyond the two every community gets exists, a rule exists, an
 * invite exists or someone else has joined. So it is right on every device and platform. The
 * one local fact is "Hide", a per-device preference.
 *
 * Owner only — the caller draws it for the owner; every write behind it is server-gated.
 */
private enum class SetupTask(val title: String, val icon: ImageVector) {
    DESCRIBE("Say what it's for", Icons.AutoMirrored.Outlined.FormatAlignLeft),
    SPACES("Add your first Spaces", Icons.Outlined.GridView),
    RULES("Set a few ground rules", Icons.Outlined.Rule),
    INVITE("Invite your first members", Icons.Outlined.PersonAdd),
}

@Composable
fun CommunitySetupCard(
    card: CommunityService.CommunityCard,
    service: CommunityService,
    onUpdated: (CommunityService.CommunityCard) -> Unit,
    onAddSpaces: () -> Unit,
    onSetRules: () -> Unit,
    onInvite: () -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val prefs = remember { context.getSharedPreferences("community_setup", Context.MODE_PRIVATE) }
    val hideKey = "hidden.${card.id}"
    var hidden by remember(card.id) { mutableStateOf(prefs.getBoolean(hideKey, false)) }
    // Null until the first load — never flash four undone tasks at a host who did three.
    var done by remember(card.id) { mutableStateOf<Set<SetupTask>?>(null) }
    var describing by remember { mutableStateOf(false) }

    // Only a change that could tick a task needs another round of requests.
    LaunchedEffect(card.id, card.description, card.member_count) {
        done = coroutineScope {
            val channels = async { runCatching { service.channels(card.id) }.getOrNull() }
            val rules = async { runCatching { service.rules(card.id) }.getOrNull() }
            val invites = async { runCatching { service.invites(card.id) }.getOrNull() }
            // A failed read counts as done: nagging about something already done is worse
            // than a missed nudge.
            buildSet {
                if (!card.description.isNullOrBlank()) add(SetupTask.DESCRIBE)
                // Announcements and General come with every community; a third is the host's.
                if (channels.await()?.let { it.size > 2 } != false) add(SetupTask.SPACES)
                if (rules.await()?.isNotEmpty() != false) add(SetupTask.RULES)
                if (card.member_count > 1 || invites.await()?.isNotEmpty() != false) add(SetupTask.INVITE)
            }
        }
    }

    val remaining = done?.let { d -> SetupTask.entries.filter { it !in d } } ?: emptyList()
    if (!hidden && remaining.isNotEmpty()) {
        val total = SetupTask.entries.size
        val doneCount = total - remaining.size
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.primary.copy(alpha = 0.35f), RoundedCornerShape(VoiidRadius.lg))
                .padding(16.dp),
        ) {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f)) {
                    Text("Finish setting up", style = VoiidFont.rounded(16, FontWeight.Bold), color = VoiidColor.textPrimary)
                    Text("Your community is live. These make it feel lived in.",
                         style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
                }
                Text("$doneCount/$total", style = VoiidFont.rounded(12, FontWeight.Bold), color = VoiidColor.primary)
                Spacer(Modifier.width(8.dp))
                Icon(
                    Icons.Outlined.VisibilityOff, "Hide this card", tint = VoiidColor.textSecondary,
                    modifier = Modifier.size(18.dp).softClickable {
                        haptics.tap()
                        hidden = true
                        prefs.edit().putBoolean(hideKey, true).apply()
                    },
                )
            }
            Spacer(Modifier.height(10.dp))
            LinearProgressIndicator(
                progress = { doneCount.toFloat() / total },
                modifier = Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)),
                color = VoiidColor.primary,
                trackColor = VoiidColor.divider,
            )
            Spacer(Modifier.height(4.dp))
            remaining.forEachIndexed { i, task ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .height(50.dp)
                        .softClickable(scale = 0.99f) {
                            haptics.tap()
                            when (task) {
                                SetupTask.DESCRIBE -> describing = true
                                SetupTask.SPACES -> onAddSpaces()
                                SetupTask.RULES -> onSetRules()
                                SetupTask.INVITE -> onInvite()
                            }
                        },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.size(30.dp).clip(CircleShape).background(VoiidColor.accentTint),
                        contentAlignment = Alignment.Center) {
                        Icon(task.icon, null, tint = VoiidColor.primary, modifier = Modifier.size(15.dp))
                    }
                    Spacer(Modifier.width(10.dp))
                    Text(task.title, style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                         modifier = Modifier.weight(1f))
                    Icon(Icons.Outlined.ChevronRight, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(18.dp))
                }
                if (i < remaining.lastIndex) HorizontalDivider(Modifier.padding(start = 40.dp), color = VoiidColor.divider)
            }
        }
    }

    if (describing) {
        DescribeCommunityDialog(card, service, onDismiss = { describing = false }) { updated ->
            describing = false
            onUpdated(updated)
        }
    }
}

/** The one setup task that is just a sentence — a dialog, not a trip to settings. */
@Composable
private fun DescribeCommunityDialog(
    card: CommunityService.CommunityCard,
    service: CommunityService,
    onDismiss: () -> Unit,
    onSaved: (CommunityService.CommunityCard) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    var about by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }

    VoiidDialog(
        onDismissRequest = onDismiss,
        title = "What's it for?",
        body = "One or two sentences. It's the first thing people read before they join.",
        confirmLabel = "Save",
        confirmEnabled = about.isNotBlank(),
        busy = saving,
        onConfirm = {
            saving = true
            failure = null
            scope.launch {
                try {
                    val updated = service.update(card.id, description = about.trim())
                    haptics.success()
                    onSaved(updated)
                } catch (e: Exception) {
                    haptics.error()
                    failure = e.message ?: "Couldn't save that."
                }
                saving = false
            }
        },
        footer = {
            Box(
                Modifier.fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.fieldFill)
                    .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.md))
                    .padding(12.dp),
            ) {
                // MAX_DESCRIPTION in the route.
                BasicTextField(
                    value = about, onValueChange = { if (it.length <= 500) about = it },
                    minLines = 3, maxLines = 6,
                    textStyle = VoiidFont.rounded(15).merge(TextStyle(color = VoiidColor.textPrimary)),
                    modifier = Modifier.fillMaxWidth(),
                    decorationBox = { inner ->
                        if (about.isEmpty()) Text("A place for…", style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                        inner()
                    },
                )
            }
            failure?.let {
                Spacer(Modifier.height(6.dp))
                Text(it, style = VoiidFont.rounded(12), color = VoiidColor.error)
            }
        },
    )
}

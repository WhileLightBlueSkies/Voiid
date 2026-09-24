package com.voiid.app.main.stories

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.VisibilityOff
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.voiid.app.main.ProfileAvatar
import com.voiid.app.model.MomentAudience
import com.voiid.app.model.MomentSettings
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidSearchField
import com.voiid.app.ui.components.VoiidToggle
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * One place for who sees your moments, instead of a picker on every post. Port of iOS
 * Main/Stories/MomentsPrivacyView.swift.
 *
 * ONE SETTING, SHOWN WHERE YOU POST. Who your moments go to is chosen here once — all your
 * connections, only your phone contacts, only people you chat with, only people you pick, or
 * nobody — and every new moment follows it. The composer shows the current choice and opens
 * this screen. "Hide from" leaves particular people out of the three group choices.
 *
 * WHAT A CHANGE DOES. It applies to NEW moments. One already shared was encrypted for the
 * people it went to; it cannot be taken back from them, and the footer says so.
 */
@Composable
fun MomentsSettingsScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    var people by remember { mutableStateOf<MomentSettings.People?>(null) }
    var picking by remember { mutableStateOf<String?>(null) }   // "selected" | "hidden"
    var showArchive by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        MomentSettings.load(context)
        people = MomentSettings.people(context)
    }
    val mode = MomentSettings.audienceMode

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp).height(56.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(38.dp).clip(CircleShape).softClickable(scale = 0.9f) { haptics.tap(); onClose() },
                    contentAlignment = Alignment.CenterStart) {
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, "Back", tint = VoiidColor.textPrimary, modifier = Modifier.size(30.dp))
                }
                Text("Moments settings", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                    textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(38.dp))
            }

            Column(
                Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp).navigationBarsPadding().padding(bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                    Text("Choose who sees the moments you share, and what's kept.",
                        style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
                    Row(Modifier.clip(RoundedCornerShape(50)).background(VoiidColor.accentTint).padding(horizontal = 10.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Default.Lock, null, tint = VoiidColor.accentInk, modifier = Modifier.size(12.dp))
                        Text("End-to-end encrypted", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.accentInk)
                    }
                }

                Section("Who can see my moments",
                    "Changes apply to new moments. A moment you've already shared stays with the people it was sent to. Voiid can't see your moments, but it does see who they're sent to.") {
                    MomentAudience.entries.forEachIndexed { i, m ->
                        if (i > 0) Divider()
                        val on = mode == m
                        val count = people?.let { p ->
                            var ids = MomentSettings.covered(m, p)
                            if (m.allowsHiding) ids = ids - MomentSettings.hiddenFrom
                            ids.size
                        }
                        val detail = if (m == MomentAudience.SELECTED && MomentSettings.selectedPeople.isNotEmpty()) {
                            val n = MomentSettings.selectedPeople.size
                            "$n ${if (n == 1) "person" else "people"} · Tap to change"
                        } else m.detail
                        SettingsRow(iconFor(m), m.title, detail, onClick = {
                            if (m == MomentAudience.SELECTED) {
                                // Choosing it opens the list: an empty "selected" would send to no one.
                                if (!on) haptics.selection()
                                MomentSettings.setAudience(context, MomentAudience.SELECTED)
                                if (MomentSettings.selectedPeople.isEmpty() || on) picking = "selected"
                                return@SettingsRow
                            }
                            if (!on) {
                                haptics.selection()
                                MomentSettings.setAudience(context, m)
                            }
                        }) {
                            if (m != MomentAudience.NOBODY && count != null) {
                                Text("$count", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                                Spacer(Modifier.width(8.dp))
                            }
                            Icon(Icons.Default.Check, null, tint = if (on) VoiidColor.accent else androidx.compose.ui.graphics.Color.Transparent,
                                modifier = Modifier.size(18.dp))
                        }
                    }
                }

                AnimatedVisibility(mode.allowsHiding, enter = fadeIn(), exit = fadeOut()) {
                    val hidden = people?.let { (MomentSettings.hiddenFrom intersect MomentSettings.covered(mode, it)).size } ?: 0
                    Section(null, "People you hide won't get your new moments, and aren't told.") {
                        SettingsRow(Icons.Default.VisibilityOff, "Hide from",
                            if (hidden == 0) "No one hidden" else "$hidden ${if (hidden == 1) "person" else "people"} hidden",
                            onClick = { picking = "hidden" }) { Chevron() }
                    }
                }

                Section("Your moments",
                    "Keep my moments saves your own moments on this phone after 24 hours. Your moments show who viewed them and when.") {
                    SettingsRow(Icons.Default.Archive, "Keep my moments", null, onClick = null) {
                        VoiidToggle(checked = MomentSettings.keepByDefault) { MomentSettings.setKeep(context, it) }
                    }
                }

                Section(null, null) {
                    SettingsRow(Icons.Default.Archive, "Archive", "Your moments kept after 24 hours",
                        onClick = { haptics.tap(); showArchive = true }) { Chevron() }
                }
                // The Moments tab's floating bar is not over this screen, but a little room past
                // the last card keeps it clear of the gesture area on every phone.
                Spacer(Modifier.height(40.dp))
            }
        }
    }

    val p = people
    if (picking != null && p != null) {
        val selecting = picking == "selected"
        MomentsPeoplePicker(
            title = if (selecting) "Share with" else "Hide from",
            prompt = if (selecting) "Only these people will see your moments." else "These people won't see your moments.",
            candidates = if (selecting) p.connections else MomentSettings.covered(mode, p),
            selection = if (selecting) MomentSettings.selectedPeople else MomentSettings.hiddenFrom,
            onDone = {
                if (selecting) MomentSettings.setSelected(context, it) else MomentSettings.setHidden(context, it)
                picking = null
            },
            onCancel = { picking = null },
        )
    }
    if (showArchive) StoryArchiveScreen(onClose = { showArchive = false })
}

private fun iconFor(m: MomentAudience): ImageVector = when (m) {
    MomentAudience.CONNECTIONS -> Icons.Default.Groups
    MomentAudience.CONTACTS -> Icons.Default.Person
    MomentAudience.CHATS -> Icons.Default.Forum
    MomentAudience.SELECTED -> Icons.Default.Checklist
    MomentAudience.NOBODY -> Icons.Default.Lock
}

@Composable
private fun Section(header: String?, footer: String?, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        header?.let {
            Text(it, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary,
                modifier = Modifier.padding(horizontal = 4.dp))
        }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard)) { content() }
        footer?.let {
            Text(it, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary, modifier = Modifier.padding(horizontal = 4.dp))
        }
    }
}

@Composable
private fun SettingsRow(
    icon: ImageVector,
    title: String,
    detail: String?,
    onClick: (() -> Unit)?,
    trailing: @Composable () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp)
            .then(if (onClick != null) Modifier.softClickable(scale = 0.99f, onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(icon, null, tint = VoiidColor.accent, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = VoiidFont.rounded(15, FontWeight.Medium), color = VoiidColor.textPrimary)
            detail?.let { Text(it, style = VoiidFont.rounded(12.5f), color = VoiidColor.textSecondary) }
        }
        Row(verticalAlignment = Alignment.CenterVertically) { trailing() }
    }
}

@Composable
private fun Divider() {
    Box(Modifier.fillMaxWidth().padding(start = 52.dp).height(1.dp).background(VoiidColor.divider))
}

@Composable
private fun Chevron() {
    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = VoiidColor.textSecondary, modifier = Modifier.size(20.dp))
}

/** A searchable list of people with checkmarks, for "Share with" and "Hide from". */
@Composable
private fun MomentsPeoplePicker(
    title: String,
    prompt: String,
    candidates: Set<String>,
    selection: Set<String>,
    onDone: (Set<String>) -> Unit,
    onCancel: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    // Edited here and committed on Done, so Cancel really cancels.
    var draft by remember { mutableStateOf(selection) }
    var query by remember { mutableStateOf("") }
    val everyone = remember(candidates) {
        candidates.map { Triple(it, UserDirectory.displayName(it), UserDirectory.photoUrl(it)) }
            .sortedBy { it.second.lowercase() }
    }
    val shown = query.trim().let { q -> if (q.isEmpty()) everyone else everyone.filter { it.second.contains(q, ignoreCase = true) } }
    BackHandler(onBack = onCancel)

    Dialog(onDismissRequest = onCancel, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding().navigationBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp).height(56.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Cancel", style = VoiidFont.rounded(16), color = VoiidColor.accentInk,
                    modifier = Modifier.softClickable(scale = 0.95f, onClick = onCancel).padding(10.dp))
                Text(if (draft.isEmpty()) title else "$title (${draft.size})", style = VoiidFont.rounded(17, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
                Text("Done", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.accentInk,
                    modifier = Modifier.softClickable(scale = 0.95f) { onDone(draft) }.padding(10.dp))
            }
            Box(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
                VoiidSearchField(query = query, onQueryChange = { query = it }, placeholder = "Search")
            }
            LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
                if (candidates.isEmpty()) {
                    item {
                        Text("No one here yet. People you add in Contacts or chat with will appear here.",
                            style = VoiidFont.rounded(14), color = VoiidColor.textSecondary, modifier = Modifier.padding(vertical = 16.dp))
                    }
                }
                items(shown, key = { it.first }) { (id, name, photo) ->
                    val on = id in draft
                    Row(
                        Modifier.fillMaxWidth().softClickable(scale = 0.99f) {
                            haptics.selection()
                            draft = if (on) draft - id else draft + id
                        }.padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        ProfileAvatar(photoUrl = photo, name = name, size = 38.dp)
                        Text(name, style = VoiidFont.rounded(16), color = VoiidColor.textPrimary, maxLines = 1, modifier = Modifier.weight(1f))
                        Icon(if (on) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked, null,
                            tint = if (on) VoiidColor.primary else VoiidColor.placeholder, modifier = Modifier.size(22.dp))
                    }
                }
                item {
                    Text(prompt, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary, modifier = Modifier.padding(vertical = 12.dp))
                }
            }
        }
    }
}

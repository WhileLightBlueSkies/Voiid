package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.AlternateEmail
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Campaign
import androidx.compose.material.icons.outlined.ChatBubble
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Help
import androidx.compose.material.icons.outlined.LocalCafe
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material.icons.outlined.Work
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.CommunityService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * The five-step community creation wizard — port of iOS `CommunityCreateFlow`.
 *
 * Five DISCRETE decisions (identity, privacy, spaces, rules, invite/review), shown as segment
 * marks rather than a continuous bar: completed segments stay lit, so going back never reads as
 * losing progress. Only step 1 is required — a community created without rules or extra Spaces
 * is a real community, not an incomplete one, so every later step is skippable via Continue.
 *
 * The handle is DERIVED from the name and can collide; the server answers 409 and the error is
 * surfaced so the user can change the name rather than silently renumbering a handle they
 * never chose.
 */
private enum class CreateStep(val title: String, val heading: String, val subheading: String) {
    IDENTITY("Identity", "Name your community", "A name and a line about it. Everything else can change later."),
    PRIVACY("Privacy", "Who can get in", "You can change this at any time."),
    SPACES("Spaces", "Pick starter Spaces", "Spaces are channels. Start with a couple and add more later."),
    RULES("Rules", "Set the ground rules", "Suggested, not imposed. Edit or remove any of them."),
    INVITE("Invite", "Ready to review", "Invite people now, or share a link once it exists.");

    val index: Int get() = ordinal
}

private data class SpaceTemplate(
    val id: String,
    val name: String,
    val detail: String,
    val icon: ImageVector,
)

private val spaceTemplates = listOf(
    SpaceTemplate("announcements", "Announcements", "Host posts, everyone reads.", Icons.Outlined.Campaign),
    SpaceTemplate("general", "General", "The room everything starts in.", Icons.Outlined.ChatBubble),
    SpaceTemplate("showcase", "Showcase", "Finished work, shown off.", Icons.Outlined.AutoAwesome),
    SpaceTemplate("help", "Help", "Questions, and people who answer them.", Icons.Outlined.Help),
    SpaceTemplate("offtopic", "Off topic", "Everything that isn't the point.", Icons.Outlined.LocalCafe),
    SpaceTemplate("jobs", "Jobs", "Who's hiring, who's looking.", Icons.Outlined.Work),
)

private data class RuleTemplate(val id: String, val title: String, val detail: String)

private val ruleTemplates = listOf(
    RuleTemplate("respect", "Be respectful", "Critique the work, never the person."),
    RuleTemplate("promo", "No unsolicited promotion", "Ads and cold pitches belong elsewhere."),
    RuleTemplate("onTopic", "Keep it on topic", "Post in the Space that fits what you're saying."),
    RuleTemplate("credit", "Credit your sources", "If it isn't yours, say whose it is and link it."),
    RuleTemplate("spam", "No spam or repeat posting", "Say it once, in one place."),
    RuleTemplate("privacy", "Respect privacy", "Don't share anyone's details without their say-so."),
)

private data class PolicyOption(val id: String, val title: String, val detail: String, val icon: ImageVector)

private val policyOptions = listOf(
    PolicyOption("open", "Anyone can join", "Open to everyone who finds it.", Icons.Outlined.Public),
    PolicyOption("approval", "Approval needed", "People ask, you decide.", Icons.Outlined.Verified),
    PolicyOption("invite_only", "Invite only", "Only people with a link get in.", Icons.Outlined.Lock),
)

private val categories = listOf("Design", "Tech", "Gaming", "Music", "Sport", "Local")

@Composable
fun CommunityCreateFlow(
    service: CommunityService,
    onCreate: (CommunityService.CommunityCard) -> Unit,
    onCancel: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()

    var step by remember { mutableStateOf(CreateStep.IDENTITY) }
    var name by remember { mutableStateOf("") }
    var about by remember { mutableStateOf("") }
    var category by remember { mutableStateOf("Design") }
    var joinPolicy by remember { mutableStateOf("approval") }
    var discoverable by remember { mutableStateOf(true) }
    var membersCanInvite by remember { mutableStateOf(true) }
    var spaceIDs by remember { mutableStateOf(setOf("general", "announcements")) }
    var ruleIDs by remember { mutableStateOf(setOf("respect", "promo", "onTopic")) }
    var creating by remember { mutableStateOf(false) }
    var createError by remember { mutableStateOf<String?>(null) }

    // Derived, not typed — mirrors iOS `handle`. Lowercase alphanumerics, max 20.
    val handle = name.lowercase()
        .replace(Regex("[^a-z0-9 ]"), "")
        .trim()
        .replace(" ", "")
        .take(20)
    val canContinue = name.trim().isNotEmpty()

    fun createNow() {
        if (creating || !canContinue) return
        creating = true
        createError = null
        scope.launch {
            try {
                val card = service.create(
                    handle = handle,
                    name = name.trim(),
                    description = about.trim().ifEmpty { null },
                    joinPolicy = joinPolicy,
                    discoverable = discoverable,
                    category = category,
                    membersCanInvite = membersCanInvite && joinPolicy != "invite_only",
                    extraChannels = spaceTemplates
                        .filter { spaceIDs.contains(it.id) && it.id != "general" && it.id != "announcements" }
                        .map { it.name },
                    rules = ruleTemplates.filter { ruleIDs.contains(it.id) }
                        .map { CommunityService.RuleInput(it.title, it.detail) },
                )
                haptics.success()
                onCreate(card)
            } catch (e: Exception) {
                haptics.error()
                createError = e.message ?: "Couldn't create that community."
            }
            creating = false
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding(),
    ) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Cancel", style = VoiidFont.rounded(15), color = VoiidColor.textSecondary,
                 modifier = Modifier.softClickable { haptics.tap(); onCancel() })
            Spacer(Modifier.weight(1f))
            Text("New Community", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(52.dp))
        }

        // Segments, not a continuous bar; completed segments stay lit.
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                CreateStep.entries.forEach { s ->
                    Box(
                        Modifier
                            .weight(1f)
                            .height(3.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(if (s.index <= step.index) VoiidColor.primary else VoiidColor.divider)
                    )
                }
            }
            Row(Modifier.padding(top = 6.dp)) {
                Text("Step ${step.index + 1} of ${CreateStep.entries.size}",
                     style = VoiidFont.rounded(11), color = VoiidColor.textSecondary)
                Spacer(Modifier.weight(1f))
                Text(step.title, style = VoiidFont.rounded(11, FontWeight.SemiBold), color = VoiidColor.primary)
            }
        }

        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            Spacer(Modifier.height(14.dp))
            Text(step.heading, style = VoiidFont.rounded(23, FontWeight.Bold), color = VoiidColor.textPrimary)
            Text(step.subheading, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
                 modifier = Modifier.padding(top = 4.dp))
            Spacer(Modifier.height(18.dp))

            when (step) {
                CreateStep.IDENTITY -> {
                    WizardField("Community name") {
                        BasicTextField(
                            value = name, onValueChange = { if (it.length <= 60) name = it },
                            singleLine = true,
                            textStyle = VoiidFont.rounded(15).merge(TextStyle(color = VoiidColor.textPrimary)),
                            modifier = Modifier.fillMaxWidth(),
                            decorationBox = { inner ->
                                if (name.isEmpty()) Text("Voiid Designers", style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                                inner()
                            },
                        )
                    }
                    if (handle.isNotEmpty()) {
                        Row(
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .background(VoiidColor.primary.copy(alpha = 0.08f))
                                .padding(horizontal = 12.dp, vertical = 9.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Outlined.AlternateEmail, null, tint = VoiidColor.primary, modifier = Modifier.size(13.dp))
                            Spacer(Modifier.width(5.dp))
                            Text(handle, style = VoiidFont.rounded(12, FontWeight.Medium), color = VoiidColor.primary)
                            Spacer(Modifier.weight(1f))
                            Text("Auto", style = VoiidFont.rounded(10, FontWeight.Bold), color = VoiidColor.textSecondary)
                        }
                        Spacer(Modifier.height(10.dp))
                    }
                    Spacer(Modifier.height(4.dp))
                    WizardField("What's it for?") {
                        BasicTextField(
                            value = about, onValueChange = { if (it.length <= 280) about = it },
                            textStyle = VoiidFont.rounded(15).merge(TextStyle(color = VoiidColor.textPrimary)),
                            modifier = Modifier.fillMaxWidth(),
                            decorationBox = { inner ->
                                if (about.isEmpty()) {
                                    Text("A community for designers to share, learn and grow together.",
                                         style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                                }
                                inner()
                            },
                        )
                    }
                    Spacer(Modifier.height(14.dp))
                    Text("Category", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.textSecondary)
                    Spacer(Modifier.height(7.dp))
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        categories.take(3).forEach { option ->
                            CategoryChip(option, category == option) { haptics.selection(); category = option }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        categories.drop(3).forEach { option ->
                            CategoryChip(option, category == option) { haptics.selection(); category = option }
                        }
                    }
                }
                CreateStep.PRIVACY -> {
                    policyOptions.forEach { policy ->
                        val selected = joinPolicy == policy.id
                        SelectableRow(policy.icon, policy.title, policy.detail, selected) {
                            haptics.selection()
                            joinPolicy = policy.id
                            // Invite-only where every member can invite is not invite-only.
                            if (policy.id == "invite_only") membersCanInvite = false
                        }
                        Spacer(Modifier.height(8.dp))
                    }
                    ToggleRow("Show in search", "People can find it without a link.", discoverable) { discoverable = it }
                    Spacer(Modifier.height(8.dp))
                    ToggleRow(
                        "Members can invite",
                        if (joinPolicy == "invite_only") "Turned off — invite-only means only you invite."
                        else "Anyone inside can bring someone in.",
                        membersCanInvite,
                        enabled = joinPolicy != "invite_only",
                    ) { membersCanInvite = it }
                }
                CreateStep.SPACES -> {
                    spaceTemplates.forEach { space ->
                        SelectableRow(space.icon, space.name, space.detail, spaceIDs.contains(space.id)) {
                            haptics.selection()
                            spaceIDs = if (spaceIDs.contains(space.id)) spaceIDs - space.id else spaceIDs + space.id
                        }
                        Spacer(Modifier.height(8.dp))
                    }
                }
                CreateStep.RULES -> {
                    ruleTemplates.forEach { rule ->
                        SelectableRow(Icons.Outlined.Verified, rule.title, rule.detail, ruleIDs.contains(rule.id)) {
                            haptics.selection()
                            ruleIDs = if (ruleIDs.contains(rule.id)) ruleIDs - rule.id else ruleIDs + rule.id
                        }
                        Spacer(Modifier.height(8.dp))
                    }
                }
                CreateStep.INVITE -> {
                    Row(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(VoiidRadius.md))
                            .background(VoiidColor.surfaceCard)
                            .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.md))
                            .padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Outlined.AlternateEmail, null, tint = Color.White,
                             modifier = Modifier.size(34.dp).clip(RoundedCornerShape(10.dp)).background(VoiidColor.primary).padding(8.dp))
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text("Share a link", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                            Text("Once it exists you get a link anyone can open.",
                                 style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
                        }
                    }
                    Spacer(Modifier.height(14.dp))
                    Column(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(VoiidRadius.md))
                            .background(VoiidColor.surfaceCard)
                            .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.md))
                            .padding(12.dp)
                    ) {
                        Text("Review", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.textSecondary)
                        Spacer(Modifier.height(8.dp))
                        SummaryRow("Name", name.ifEmpty { "—" })
                        SummaryRow("Handle", if (handle.isEmpty()) "—" else "@$handle")
                        SummaryRow("Category", category)
                        SummaryRow("Joining", policyOptions.firstOrNull { it.id == joinPolicy }?.title ?: "—")
                        SummaryRow("In search", if (discoverable) "Yes" else "No")
                        SummaryRow("Spaces", "${spaceIDs.size}")
                        SummaryRow("Rules", "${ruleIDs.size}")
                    }
                }
            }
            createError?.let {
                Spacer(Modifier.height(12.dp))
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            }
            Spacer(Modifier.height(16.dp))
        }

        // Footer: Back + Continue/Create.
        Row(
            Modifier.fillMaxWidth().background(VoiidColor.surfaceCard).padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (step != CreateStep.IDENTITY) {
                Box(
                    Modifier
                        .width(88.dp)
                        .height(46.dp)
                        .clip(RoundedCornerShape(999.dp))
                        .background(VoiidColor.fieldFill)
                        .softClickable { haptics.tap(); step = CreateStep.entries[step.index - 1] },
                    contentAlignment = Alignment.Center,
                ) {
                    Text("Back", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                }
            }
            Box(
                Modifier
                    .weight(1f)
                    .height(46.dp)
                    .alpha(if (canContinue && !creating) 1f else 0.5f)
                    .clip(RoundedCornerShape(999.dp))
                    .background(VoiidColor.primary)
                    .softClickable(enabled = canContinue && !creating) {
                        haptics.tap()
                        if (step == CreateStep.INVITE) createNow()
                        else step = CreateStep.entries[step.index + 1]
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (creating) "Creating…" else if (step == CreateStep.INVITE) "Create community" else "Continue",
                    style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textOnPrimary,
                )
            }
        }
    }
}

@Composable
private fun CategoryChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(if (selected) VoiidColor.primary else VoiidColor.surfaceCard)
            .border(1.dp, if (selected) Color.Transparent else VoiidColor.fieldBorder, RoundedCornerShape(999.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 15.dp, vertical = 8.dp),
    ) {
        Text(label, style = VoiidFont.rounded(13, FontWeight.SemiBold),
             color = if (selected) VoiidColor.textOnPrimary else VoiidColor.textPrimary)
    }
}

@Composable
private fun WizardField(label: String, content: @Composable () -> Unit) {
    Column {
        Text(label, style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.textSecondary)
        Spacer(Modifier.height(7.dp))
        Box(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidColor.fieldFill)
                .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.md))
                .padding(horizontal = 12.dp, vertical = 12.dp),
        ) { content() }
    }
}

@Composable
private fun SelectableRow(icon: ImageVector, title: String, detail: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(if (selected) VoiidColor.primary.copy(alpha = 0.08f) else VoiidColor.surfaceCard)
            .border(
                if (selected) 1.5.dp else 1.dp,
                if (selected) VoiidColor.primary else VoiidColor.fieldBorder,
                RoundedCornerShape(VoiidRadius.md),
            )
            .clickable(onClick = onClick)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = if (selected) VoiidColor.primary else VoiidColor.textSecondary, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Text(detail, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
        }
        Spacer(Modifier.width(8.dp))
        Icon(
            Icons.Default.CheckCircle, null,
            tint = if (selected) VoiidColor.primary else VoiidColor.fieldBorder,
            modifier = Modifier.size(21.dp),
        )
    }
}

@Composable
private fun ToggleRow(title: String, detail: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .alpha(if (enabled) 1f else 0.5f)
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.md))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Text(detail, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
        }
        com.voiid.app.ui.components.VoiidToggle(checked = checked && enabled, onCheckedChange = { if (enabled) onChange(it) })
    }
}

@Composable
private fun SummaryRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(label, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        Spacer(Modifier.weight(1f))
        Text(value, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textPrimary, maxLines = 1)
    }
}

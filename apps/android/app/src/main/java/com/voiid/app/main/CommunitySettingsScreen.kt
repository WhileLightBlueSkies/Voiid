package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.CommunityService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidToggle
import com.voiid.app.ui.components.pressableClickable
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.launch

/**
 * The host's community settings. Port of iOS `CommunitySettingsView.swift`.
 *
 * ── THE DRAFT IS NOT THE CARD ────────────────────────────────────────────────────
 * Every field edits local draft state and nothing is written until Save. [dirty] compares
 * the draft against the server's card field by field, and only what CHANGED is sent — a
 * PATCH that echoes unchanged values would clobber a concurrent edit by a co-admin.
 *
 * ── INPUT IS TRUNCATED AT THE KEYSTROKE, NEVER VALIDATED ON SUBMIT ───────────────
 * Every field caps with `take(limit)`, so the over-limit state is unreachable and there is
 * no "too long" error to write. The counter appears at 80% of the limit as a warning.
 *
 * ── THE SCREEN HAS NO ROLE CHECK OF ITS OWN ──────────────────────────────────────
 * It is only reachable from the overflow menu when the caller owns the community, and the
 * server enforces manager on every write. A non-manager who arrived here anyway sees the
 * 403 surfaced as [saveFailure] rather than a client-side lie about what they may do.
 */
private object Limits {
    const val NAME = 60
    const val DESCRIPTION = 500
    const val RULE_TITLE = 120
    const val RULE_DETAIL = 400
    const val RULES = 20
}

@Composable
fun CommunitySettingsScreen(
    card: CommunityService.CommunityCard,
    onSaved: (CommunityService.CommunityCard) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val svc = remember { CommunityService(context) }

    var current by remember { mutableStateOf(card) }
    var name by remember { mutableStateOf(current.name) }
    var about by remember { mutableStateOf(current.description ?: "") }
    var discoverable by remember { mutableStateOf(current.discoverable) }
    var joinPolicy by remember { mutableStateOf(current.join_policy) }

    var saving by remember { mutableStateOf(false) }
    var saveFailure by remember { mutableStateOf<String?>(null) }
    var saved by remember { mutableStateOf(false) }

    var rules by remember { mutableStateOf<List<CommunityService.Rule>>(emptyList()) }
    var rulesLoading by remember { mutableStateOf(true) }
    var rulesError by remember { mutableStateOf<String?>(null) }
    var ruleBusy by remember { mutableStateOf<Set<String>>(emptySet()) }
    var editingRule by remember { mutableStateOf<RuleDraft?>(null) }
    var pendingDelete by remember { mutableStateOf<CommunityService.Rule?>(null) }

    suspend fun loadRules() {
        rulesLoading = true
        runCatching { svc.rules(current.id) }
            .onSuccess { rules = it; rulesError = null }
            // The existing list is NOT cleared on failure — a rules list that empties itself
            // because the network blinked reads as "the host deleted the rules".
            .onFailure { rulesError = it.message ?: "Couldn't load the rules." }
        rulesLoading = false
    }

    LaunchedEffect(current.id) { loadRules() }

    val trimmedName = name.trim()
    val sanitisedPolicy = JoinPolicyOption.sanitised(joinPolicy, current.join_policy)
    val dirty = trimmedName != current.name ||
        about.trim() != (current.description ?: "") ||
        discoverable != current.discoverable ||
        sanitisedPolicy != current.join_policy
    val canSave = dirty && trimmedName.isNotEmpty() && !saving

    Column(
        Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding(),
    ) {
        // ── Toolbar ──────────────────────────────────────────────────────────────
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Spacer(Modifier.weight(1f))
            Text(
                "Done",
                style = VoiidFont.rounded(15, FontWeight.Medium),
                color = VoiidColor.textSecondary,
                modifier = Modifier.softClickable(enabled = !saving, onClick = onClose),
            )
        }

        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.lg),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Community settings", style = VoiidFont.rounded(34, FontWeight.Bold),
                    color = VoiidColor.textPrimary)
                Text(
                    "Who can find @${current.handle}, who can join it, and what they agree to.",
                    style = VoiidFont.rounded(15), color = VoiidColor.textSecondary,
                )
            }

            // A failure wins over a success — the newer fact is the one worth stating.
            when {
                saveFailure != null -> StatusBanner(
                    CommunityIcon.WARNING_FILL, VoiidColor.error, saveFailure!!,
                )
                saved -> StatusBanner(
                    CommunityIcon.CHECK, VoiidColor.accentInk, "Settings saved.",
                )
            }

            // ── Identity ─────────────────────────────────────────────────────────
            CardSection(
                header = "Identity",
                footer = "The handle @${current.handle} can't be changed — every invite link " +
                    "and pasted URL already points at it.",
            ) {
                SettingsField(
                    label = "Name", placeholder = "Community name",
                    value = name, limit = Limits.NAME,
                    onChange = { name = it.take(Limits.NAME) },
                )
                RowDivider()
                SettingsField(
                    label = "Description", placeholder = "What this community is for.",
                    value = about, limit = Limits.DESCRIPTION, multiline = true,
                    onChange = { about = it.take(Limits.DESCRIPTION) },
                )
            }

            // ── Discovery ────────────────────────────────────────────────────────
            CardSection(
                header = "Discovery",
                footer = if (discoverable)
                    "This community appears in search to people who aren't members."
                else
                    "This community is hidden from search. People who aren't members can " +
                        "only reach it with a link you give them.",
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 11.dp),
                    horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RowIcon(CommunityIcon.SEARCH)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        Text("Show in search", style = VoiidFont.rounded(17),
                            color = VoiidColor.textPrimary)
                        Text("Let people who aren't members find this community.",
                            style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                    }
                    VoiidToggle(checked = discoverable, onCheckedChange = { discoverable = it })
                }
            }

            // ── Joining ──────────────────────────────────────────────────────────
            CardSection(
                header = "Joining",
                footer = JoinPolicyOption.find(joinPolicy)?.explanation,
            ) {
                JoinPolicyOption.all.forEachIndexed { index, option ->
                    if (index > 0) RowDivider()
                    PolicyRow(
                        option = option,
                        selected = joinPolicy == option.id,
                        onSelect = { haptics.selection(); joinPolicy = option.id },
                    )
                }
            }

            // ── Rules ────────────────────────────────────────────────────────────
            CardSection(
                header = "Rules",
                footer = "Shown on the About tab to everyone who can see this community, " +
                    "including people deciding whether to join.",
            ) {
                when {
                    rulesLoading && rules.isEmpty() -> Box(
                        Modifier.fillMaxWidth().padding(vertical = VoiidSpacing.lg),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(color = VoiidColor.accent, strokeWidth = 2.dp,
                            modifier = Modifier.size(22.dp))
                    }
                    rulesError != null && rules.isEmpty() -> Column(
                        Modifier.fillMaxWidth().padding(vertical = VoiidSpacing.lg,
                            horizontal = 16.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(rulesError!!, style = VoiidFont.rounded(13),
                            color = VoiidColor.textSecondary)
                        Text("Try again", style = VoiidFont.rounded(13, FontWeight.SemiBold),
                            color = VoiidColor.accentInk,
                            modifier = Modifier.pressableClickable {
                                scope.launch { loadRules() }
                            })
                    }
                    rules.isEmpty() -> Box(
                        Modifier.fillMaxWidth().padding(vertical = VoiidSpacing.lg,
                            horizontal = 16.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text("No rules yet. Members see nothing here until you add one.",
                            style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                    }
                    else -> rules.forEachIndexed { index, rule ->
                        if (index > 0) RowDivider()
                        SettingsRuleRow(
                            number = index + 1, rule = rule,
                            busy = ruleBusy.contains(rule.id),
                            canMoveUp = index > 0, canMoveDown = index < rules.size - 1,
                            onEdit = { editingRule = RuleDraft(rule, rule.order) },
                            onDelete = { pendingDelete = rule },
                            onMove = { up ->
                                val other = rules.getOrNull(if (up) index - 1 else index + 1)
                                    ?: return@SettingsRuleRow
                                if (ruleBusy.contains(rule.id) || ruleBusy.contains(other.id)) {
                                    return@SettingsRuleRow
                                }
                                scope.launch {
                                    ruleBusy = ruleBusy + rule.id + other.id
                                    runCatching {
                                        // Two PATCHes swapping positions. The local list is
                                        // updated only after BOTH land — a half-applied swap
                                        // shown as done is a list that lies.
                                        svc.updateRule(current.id, rule.id, rule.title,
                                            rule.detail, other.order)
                                        svc.updateRule(current.id, other.id, other.title,
                                            other.detail, rule.order)
                                    }.onSuccess {
                                        haptics.selection(); loadRules()
                                    }.onFailure {
                                        haptics.error()
                                        rulesError = it.message ?: "Couldn't reorder the rules."
                                        loadRules()   // re-read the true server order
                                    }
                                    ruleBusy = ruleBusy - rule.id - other.id
                                }
                            },
                        )
                    }
                }

                RowDivider()
                val atCeiling = rules.size >= Limits.RULES
                Row(
                    Modifier
                        .fillMaxWidth()
                        .alpha(if (atCeiling) 0.45f else 1f)
                        .pressableClickable(enabled = !rulesLoading && !atCeiling) {
                            haptics.tap()
                            editingRule = RuleDraft(null, (rules.lastOrNull()?.order ?: -1) + 1)
                        }
                        .padding(horizontal = 16.dp, vertical = 11.dp),
                    horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RowIcon(CommunityIcon.PLUS)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        Text("Add a rule", style = VoiidFont.rounded(17),
                            color = VoiidColor.textPrimary)
                        if (atCeiling) {
                            Text("You've reached the limit of ${Limits.RULES}.",
                                style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                        }
                    }
                }
            }

            Spacer(Modifier.height(72.dp))
        }

        // ── The save bar ─────────────────────────────────────────────────────────
        Box(
            Modifier
                .fillMaxWidth()
                .background(VoiidColor.background.copy(alpha = 0.94f))
                .padding(horizontal = 16.dp, vertical = VoiidSpacing.sm)
                .navigationBarsPadding(),
        ) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(48.dp)
                    .clip(RoundedCornerShape(VoiidRadius.pill))
                    .background(if (canSave) VoiidColor.accent else VoiidColor.surfaceCard)
                    .then(
                        if (canSave) Modifier
                        else Modifier.border(1.dp, VoiidColor.divider,
                            RoundedCornerShape(VoiidRadius.pill))
                    )
                    .pressableClickable(enabled = canSave) {
                        haptics.tap()
                        scope.launch {
                            saving = true; saveFailure = null; saved = false
                            runCatching {
                                svc.update(
                                    communityId = current.id,
                                    // Only what CHANGED is sent. An unchanged field is null,
                                    // and null means "leave this column alone".
                                    name = trimmedName.takeIf { it != current.name },
                                    description = about.trim()
                                        .takeIf { it != (current.description ?: "") },
                                    joinPolicy = sanitisedPolicy
                                        .takeIf { it != current.join_policy },
                                    discoverable = discoverable
                                        .takeIf { it != current.discoverable },
                                )
                            }.onSuccess { updated ->
                                // Re-seed the whole draft from the RESPONSE, so the server's
                                // own trimming shows up rather than the text as typed.
                                current = updated
                                name = updated.name
                                about = updated.description ?: ""
                                discoverable = updated.discoverable
                                joinPolicy = updated.join_policy
                                saved = true
                                haptics.success()
                                onSaved(updated)
                            }.onFailure {
                                haptics.error()
                                saveFailure = it.message ?: "Couldn't save those settings."
                            }
                            saving = false
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                if (saving) {
                    CircularProgressIndicator(color = VoiidColor.textOnAccent, strokeWidth = 2.dp,
                        modifier = Modifier.size(20.dp))
                } else {
                    Text("Save changes", style = VoiidFont.rounded(17, FontWeight.SemiBold),
                        color = if (canSave) VoiidColor.textOnAccent else VoiidColor.textSecondary)
                }
            }
        }
    }

    editingRule?.let { draft ->
        CommunityRuleEditor(
            draft = draft,
            communityId = current.id,
            onClose = { editingRule = null },
            onSaved = { savedRule, wasNew ->
                rules = if (wasNew) rules + savedRule
                        else rules.map { if (it.id == savedRule.id) savedRule else it }
                rules = rules.sortedBy { it.order }
                editingRule = null
            },
        )
    }

    pendingDelete?.let { rule ->
        VoiidConfirmDialog(
            title = "Delete this rule?",
            message = "“${rule.text}” will be removed for everyone.",
            confirmLabel = "Delete",
            destructive = true,
            onCancel = { pendingDelete = null },
            onConfirm = {
                pendingDelete = null
                if (!ruleBusy.contains(rule.id)) scope.launch {
                    ruleBusy = ruleBusy + rule.id
                    runCatching { svc.deleteRule(current.id, rule.id) }
                        .onSuccess {
                            rules = rules.filterNot { it.id == rule.id }
                            haptics.success()
                        }
                        .onFailure {
                            haptics.error()
                            rulesError = it.message ?: "Couldn't delete that rule."
                        }
                    ruleBusy = ruleBusy - rule.id
                }
            },
        )
    }
}

/** The rule being edited. A null [rule] means this is a new one. */
data class RuleDraft(val rule: CommunityService.Rule?, val position: Int) {
    val isNew: Boolean get() = rule == null
}

// ══════════════════════════════════════════════════════════════════════════════════
//  THE RULE EDITOR
// ══════════════════════════════════════════════════════════════════════════════════

@Composable
private fun CommunityRuleEditor(
    draft: RuleDraft,
    communityId: String,
    onClose: () -> Unit,
    onSaved: (CommunityService.Rule, Boolean) -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()
    val svc = remember { CommunityService(context) }

    var title by remember { mutableStateOf(draft.rule?.text ?: "") }
    var detail by remember { mutableStateOf(draft.rule?.explanation ?: "") }
    var busy by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }

    val trimmedTitle = title.trim()
    // The ONLY validation. Detail is genuinely optional.
    val canConfirm = trimmedTitle.isNotEmpty() && !busy

    com.voiid.app.ui.components.VoiidDialogCustom(onDismissRequest = onClose) {
        Column(
            Modifier.fillMaxWidth().padding(VoiidSpacing.md),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
        ) {
            Text(if (draft.isNew) "New rule" else "Edit rule",
                style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary)
            Text(
                "Everyone who can see this community can read this, including people " +
                    "deciding whether to join.",
                style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
            )

            EditorField("Rule", "Be useful, not loud", title, Limits.RULE_TITLE) {
                title = it.take(Limits.RULE_TITLE)
            }
            EditorField("Detail (optional)", "Critique the work, never the person.",
                detail, Limits.RULE_DETAIL, multiline = true) {
                detail = it.take(Limits.RULE_DETAIL)
            }

            failure?.let {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(VoiidRadius.md))
                        .background(VoiidColor.error.copy(alpha = 0.10f))
                        .border(1.dp, VoiidColor.error.copy(alpha = 0.35f),
                            RoundedCornerShape(VoiidRadius.md))
                        .padding(VoiidSpacing.md),
                    horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                    verticalAlignment = Alignment.Top,
                ) {
                    CommunityGlyph(CommunityIcon.WARNING_FILL, size = 13.dp, tint = VoiidColor.error)
                    Text(it, style = VoiidFont.rounded(13), color = VoiidColor.textPrimary)
                }
            }

            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Spacer(Modifier.weight(1f))
                Text("Cancel", style = VoiidFont.rounded(15),
                    color = VoiidColor.textSecondary,
                    modifier = Modifier.pressableClickable(enabled = !busy, onClick = onClose)
                        .padding(VoiidSpacing.sm))
                Text(
                    if (draft.isNew) "Add" else "Save",
                    style = VoiidFont.rounded(15, FontWeight.SemiBold),
                    color = if (canConfirm) VoiidColor.accentInk else VoiidColor.textSecondary,
                    modifier = Modifier
                        .pressableClickable(enabled = canConfirm) {
                            scope.launch {
                                busy = true; failure = null
                                runCatching {
                                    if (draft.isNew) {
                                        svc.createRule(communityId, trimmedTitle,
                                            detail.trim().ifEmpty { null })
                                    } else {
                                        // `position` is deliberately NOT sent — editing a
                                        // rule must never move it.
                                        svc.updateRule(communityId, draft.rule!!.id,
                                            trimmedTitle, detail.trim().ifEmpty { null })
                                    }
                                }.onSuccess {
                                    haptics.success(); onSaved(it, draft.isNew)
                                }.onFailure {
                                    // The editor STAYS OPEN with the text intact.
                                    haptics.error()
                                    failure = it.message ?: "Couldn't save that rule."
                                }
                                busy = false
                            }
                        }
                        .padding(VoiidSpacing.sm),
                )
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════════
//  SHARED CHROME
// ══════════════════════════════════════════════════════════════════════════════════

@Composable
private fun CardSection(
    header: String,
    footer: String?,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(header, style = VoiidFont.rounded(13, FontWeight.SemiBold),
            color = VoiidColor.textSecondary, modifier = Modifier.padding(start = 4.dp))
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.lg)),
            content = content,
        )
        footer?.let {
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                modifier = Modifier.padding(horizontal = 4.dp))
        }
    }
}

@Composable
private fun RowDivider() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(VoiidColor.divider))
}

/** The 34dp outlined circle that leads every settings row. */
@Composable
private fun RowIcon(icon: CommunityIcon, destructive: Boolean = false) {
    val tint = if (destructive) VoiidColor.error else VoiidColor.accentInk
    Box(
        Modifier
            .size(34.dp)
            .border(1.dp, tint.copy(alpha = 0.5f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        CommunityGlyph(icon, size = 15.dp, tint = tint)
    }
}

@Composable
private fun StatusBanner(icon: CommunityIcon, tint: Color, text: String) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(tint.copy(alpha = 0.10f))
            .border(1.dp, tint.copy(alpha = 0.35f), RoundedCornerShape(VoiidRadius.md))
            .padding(VoiidSpacing.md),
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        verticalAlignment = Alignment.Top,
    ) {
        CommunityGlyph(icon, size = 13.dp, tint = tint)
        Text(text, style = VoiidFont.rounded(13), color = VoiidColor.textPrimary)
    }
}

@Composable
private fun SettingsField(
    label: String,
    placeholder: String,
    value: String,
    limit: Int,
    multiline: Boolean = false,
    onChange: (String) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 11.dp),
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
        verticalAlignment = Alignment.Top,
    ) {
        RowIcon(if (multiline) CommunityIcon.COMPOSE else CommunityIcon.PENCIL)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(label, style = VoiidFont.rounded(13, FontWeight.SemiBold),
                    color = VoiidColor.textSecondary)
                Spacer(Modifier.weight(1f))
                // Appears at 80% of the limit, in warning only once the cap is reached.
                if (value.length >= (limit * 4) / 5) {
                    Text(
                        (limit - value.length).toString(),
                        style = VoiidFont.rounded(13, FontWeight.SemiBold)
                            .copy(fontFeatureSettings = "tnum"),
                        color = if (value.length >= limit) VoiidColor.warning
                                else VoiidColor.textSecondary,
                    )
                }
            }
            Box(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.fieldFill)
                    .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.md))
                    .padding(horizontal = 10.dp, vertical = 9.dp),
            ) {
                if (value.isEmpty()) {
                    Text(placeholder, style = VoiidFont.rounded(17),
                        color = VoiidColor.placeholder)
                }
                BasicTextField(
                    value = value, onValueChange = onChange,
                    textStyle = VoiidFont.rounded(17).copy(color = VoiidColor.textPrimary),
                    cursorBrush = SolidColor(VoiidColor.accent),
                    singleLine = !multiline,
                    minLines = if (multiline) 2 else 1,
                    maxLines = if (multiline) 5 else 1,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
private fun EditorField(
    label: String, placeholder: String, value: String, limit: Int,
    multiline: Boolean = false, onChange: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = VoiidFont.rounded(12.5f, FontWeight.SemiBold),
                color = VoiidColor.textSecondary)
            Spacer(Modifier.weight(1f))
            if (value.length >= (limit * 4) / 5) {
                Text(
                    (limit - value.length).toString(),
                    style = VoiidFont.rounded(12, FontWeight.SemiBold)
                        .copy(fontFeatureSettings = "tnum"),
                    color = if (value.length >= limit) VoiidColor.warning
                            else VoiidColor.textSecondary,
                )
            }
        }
        Box(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidColor.fieldFill)
                .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.md))
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            if (value.isEmpty()) {
                Text(placeholder, style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
            }
            BasicTextField(
                value = value, onValueChange = onChange,
                textStyle = VoiidFont.rounded(15).copy(color = VoiidColor.textPrimary),
                cursorBrush = SolidColor(VoiidColor.accent),
                singleLine = !multiline,
                minLines = if (multiline) 3 else 1,
                maxLines = if (multiline) 6 else 1,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun PolicyRow(
    option: JoinPolicyOption,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .alpha(if (option.available) 1f else 0.45f)
            // An UNAVAILABLE option is not a disabled button — it is not a control at all,
            // so it neither consumes the tap nor announces itself as pressable.
            .then(if (option.available) Modifier.pressableClickable(onClick = onSelect)
                  else Modifier.semantics { contentDescription = "${option.label}, coming soon" })
            .padding(horizontal = 16.dp, vertical = 11.dp),
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RowIcon(option.icon)
        Text(option.label, style = VoiidFont.rounded(17), color = VoiidColor.textPrimary)
        if (!option.available) {
            Text("COMING SOON", style = VoiidFont.rounded(9.5f, FontWeight.Bold),
                color = VoiidColor.textSecondary,
                modifier = Modifier
                    .clip(RoundedCornerShape(VoiidRadius.pill))
                    .background(VoiidColor.fieldFill)
                    .padding(horizontal = 6.dp, vertical = 2.dp))
        }
        Spacer(Modifier.weight(1f))
        if (selected) {
            CommunityGlyph(CommunityIcon.CHECK, size = 14.dp, tint = VoiidColor.accentInk)
        }
    }
}

@Composable
private fun SettingsRuleRow(
    number: Int,
    rule: CommunityService.Rule,
    busy: Boolean,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onMove: (Boolean) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 11.dp),
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            Modifier.size(34.dp).border(1.dp, VoiidColor.accent.copy(alpha = 0.5f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(number.toString(), style = VoiidFont.rounded(13, FontWeight.Bold),
                color = VoiidColor.accentInk)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(rule.text, style = VoiidFont.rounded(17), color = VoiidColor.textPrimary)
            if (rule.explanation.isNotEmpty()) {
                Text(rule.explanation, style = VoiidFont.rounded(13),
                    color = VoiidColor.textSecondary)
            }
        }
        if (busy) {
            CircularProgressIndicator(color = VoiidColor.accent, strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp))
        } else {
            Box {
                Box(
                    Modifier
                        .size(34.dp)
                        .pressableClickable { menuOpen = true }
                        .semantics { contentDescription = "Manage rule $number" },
                    contentAlignment = Alignment.Center,
                ) {
                    CommunityGlyph(CommunityIcon.ELLIPSIS, size = 15.dp,
                        tint = VoiidColor.textSecondary)
                }
                CommunityMenu(menuOpen, { menuOpen = false }) {
                    CommunityMenuItem("Edit", CommunityIcon.PENCIL) {
                        menuOpen = false; haptics.tap(); onEdit()
                    }
                    // Reordering is two explicit menu items, not a drag: these are cards in a
                    // scrolling column, not a List, and a drag handle here would fight the scroll.
                    CommunityMenuItem("Move up", CommunityIcon.ARROW_UP, enabled = canMoveUp) {
                        menuOpen = false; onMove(true)
                    }
                    CommunityMenuItem("Move down", CommunityIcon.ARROW_DOWN,
                        enabled = canMoveDown) {
                        menuOpen = false; onMove(false)
                    }
                    CommunityMenuDivider()
                    CommunityMenuItem("Delete", CommunityIcon.TRASH, destructive = true) {
                        menuOpen = false; haptics.tap(); onDelete()
                    }
                }
            }
        }
    }
}

package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material3.Icon
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.voiid.app.net.ApiError
import com.voiid.app.net.CommunityService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.Normalizer

/**
 * Creating a community — two steps. Port of iOS `CommunityCreateFlow`; the two must ask the
 * same things in the same order.
 *
 * Step 1 is identity (a name and an optional category). Step 2 is who can join — asked up
 * front because it is the decision that is costly to get wrong later: a community created open
 * has already let people in by the time its host finds the setting. Description, extra Spaces,
 * rules and invites are left for the "Finish setting up" card on the community's Home
 * ([CommunitySetupCard]).
 *
 * The handle is derived from the name, shown, editable in place, and checked against the
 * server as it changes (`GET /communities/handle-available`) — rather than failing with a 409
 * on the last tap.
 *
 * PARITY GAP: iOS also offers an icon at creation. Android has no community-image upload yet
 * (settings has no avatar picker either), so the icon is left out here rather than offered and
 * silently dropped.
 */
private enum class CreateStep(val number: Int) { IDENTITY(1), JOINING(2) }

private enum class HandleAvailability { CHECKING, AVAILABLE, TAKEN, UNKNOWN }

/** Mirrors iOS `CommunityHandle`; the format rules are the server's `HANDLE_RE`. */
internal object CommunityHandle {
    const val MAX_LENGTH = 20

    fun suggest(name: String): String {
        // "Café Noir" → "cafenoir": fold accents rather than drop the letters.
        val folded = Normalizer.normalize(name, Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
            .lowercase()
        var handle = folded.filter { it in 'a'..'z' || it in '0'..'9' }
        // Must start with a letter: "2026 Batch" → "batch2026".
        val leadingDigits = handle.takeWhile { it.isDigit() }
        handle = handle.drop(leadingDigits.length) + leadingDigits
        if (handle.firstOrNull()?.isLetter() != true) return ""
        // Too short to be valid: "AI" → "aicommunity".
        if (handle.length < 3) handle += "community"
        return handle.take(MAX_LENGTH)
    }

    fun numbered(base: String, n: Int): String {
        val suffix = n.toString()
        return base.take(MAX_LENGTH - suffix.length) + suffix
    }

    fun sanitise(typed: String): String =
        typed.lowercase().filter { it in 'a'..'z' || it in '0'..'9' || it == '_' }.take(MAX_LENGTH)

    fun formatProblem(handle: String): String? = when {
        handle.isEmpty() -> "Pick an address for your community."
        handle.first().isLetter().not() -> "Start the address with a letter."
        handle.length < 3 -> "Use at least 3 characters."
        else -> null
    }
}

/** Mirrors iOS `CommunityCategory.all`. Free text server-side — a convenience, not a rule. */
internal val communityCategories =
    listOf("Education", "Design", "Tech", "Gaming", "Music", "Sport", "Local", "Business")

private data class PolicyOption(val id: String, val title: String, val detail: String, val icon: ImageVector)

/** Same labels and explanations as iOS `JoinPolicyOption` (the settings screen's copy). */
private val policyOptions = listOf(
    PolicyOption("open", "Open to all", "Anyone who finds this community joins instantly.", Icons.Outlined.Public),
    PolicyOption("approval", "Request to join", "People ask to join and you review each request.", Icons.Outlined.Verified),
    PolicyOption("invite_only", "Invite only", "The only way in is an invite link or an invite from a member.", Icons.Outlined.Lock),
)

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
    var category by remember { mutableStateOf("") }
    // Open by default — the first option, so Create without a choice does what the screen shows.
    var joinPolicy by remember { mutableStateOf("open") }

    // Null while the handle follows the name; set the moment the host edits it.
    var customHandle by remember { mutableStateOf<String?>(null) }
    var resolvedSuggestion by remember { mutableStateOf("") }
    var availability by remember { mutableStateOf(HandleAvailability.CHECKING) }

    var creating by remember { mutableStateOf(false) }
    var createError by remember { mutableStateOf<String?>(null) }

    val trimmedName = name.trim()
    val suggestion = CommunityHandle.suggest(name)
    val handle = customHandle ?: resolvedSuggestion.ifEmpty { suggestion }
    val handleProblem = CommunityHandle.formatProblem(handle)
        ?: if (availability == HandleAvailability.TAKEN) "That address is taken. Try another." else null
    val showsHandleProblem = handleProblem != null && (customHandle != null || trimmedName.isNotEmpty())
    val canContinue = trimmedName.isNotEmpty() && handleProblem == null &&
        availability != HandleAvailability.CHECKING

    suspend fun isFree(candidate: String): HandleAvailability = try {
        if (service.handleAvailable(candidate).available) HandleAvailability.AVAILABLE
        else HandleAvailability.TAKEN
    } catch (e: Exception) {
        // The create route is the real check; a failed advisory call must not block the host.
        HandleAvailability.UNKNOWN
    }

    // Debounced and cancelled by the next keystroke. A derived handle steps past taken ones
    // (name2, name3 …); a typed one is only checked, never rewritten.
    LaunchedEffect(suggestion, customHandle) {
        availability = HandleAvailability.CHECKING
        if (customHandle == null) resolvedSuggestion = ""
        delay(350)
        val custom = customHandle
        if (custom != null) {
            availability = if (CommunityHandle.formatProblem(custom) != null) HandleAvailability.UNKNOWN
                           else isFree(custom)
            return@LaunchedEffect
        }
        if (CommunityHandle.formatProblem(suggestion) != null) {
            availability = HandleAvailability.UNKNOWN
            return@LaunchedEffect
        }
        for (candidate in listOf(suggestion) + (2..5).map { CommunityHandle.numbered(suggestion, it) }) {
            val result = isFree(candidate)
            if (result != HandleAvailability.TAKEN) {
                resolvedSuggestion = candidate
                availability = result
                return@LaunchedEffect
            }
        }
        resolvedSuggestion = suggestion
        availability = HandleAvailability.TAKEN
    }

    fun createNow() {
        if (creating || !canContinue) return
        creating = true
        createError = null
        scope.launch {
            try {
                val card = service.create(
                    handle = handle,
                    name = trimmedName,
                    description = null,
                    joinPolicy = joinPolicy,
                    discoverable = true,
                    category = category.ifEmpty { null },
                    membersCanInvite = joinPolicy != "invite_only",
                )
                haptics.success()
                onCreate(card)
            } catch (e: Exception) {
                haptics.error()
                if (e is ApiError.Http && e.status == 409) {
                    // The race the advisory check cannot close: someone took the handle
                    // between the check and the insert. Back to the field that fixes it.
                    customHandle = handle
                    availability = HandleAvailability.TAKEN
                    step = CreateStep.IDENTITY
                } else {
                    createError = e.message ?: "Couldn't create that community."
                }
            }
            creating = false
        }
    }

    // System back on step 2 goes to step 1, like the on-screen Back — never out of the flow.
    BackHandler(enabled = step == CreateStep.JOINING && !creating) {
        step = CreateStep.IDENTITY
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding()
            .imePadding(),
    ) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (step == CreateStep.IDENTITY) "Cancel" else "‹ Back",
                style = VoiidFont.rounded(15), color = VoiidColor.textSecondary,
                modifier = Modifier.softClickable(enabled = !creating) {
                    haptics.tap()
                    if (step == CreateStep.IDENTITY) onCancel() else { createError = null; step = CreateStep.IDENTITY }
                },
            )
            Spacer(Modifier.weight(1f))
            Text("New community", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Text("${step.number} of 2", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.textSecondary,
                 modifier = Modifier.width(52.dp))
        }

        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            Spacer(Modifier.height(14.dp))
            when (step) {
                CreateStep.IDENTITY -> {
                    Text("Bring your people together", style = VoiidFont.rounded(24, FontWeight.Bold), color = VoiidColor.textPrimary)
                    Text("Start with a name. You can add a description, Spaces and rules once it's live.",
                         style = VoiidFont.rounded(14), color = VoiidColor.textSecondary, modifier = Modifier.padding(top = 4.dp))
                    Spacer(Modifier.height(18.dp))

                    Text("Community name", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.textSecondary)
                    Spacer(Modifier.height(7.dp))
                    FieldBox {
                        BasicTextField(
                            value = name, onValueChange = { if (it.length <= 60) name = it },
                            singleLine = true,
                            textStyle = VoiidFont.rounded(16).merge(TextStyle(color = VoiidColor.textPrimary)),
                            modifier = Modifier.fillMaxWidth(),
                            decorationBox = { inner ->
                                if (name.isEmpty()) Text("Northstar Photography Club", style = VoiidFont.rounded(16), color = VoiidColor.placeholder)
                                inner()
                            },
                        )
                    }
                    Spacer(Modifier.height(7.dp))

                    // ── Handle ──
                    if (customHandle == null) {
                        Row(Modifier.fillMaxWidth().padding(start = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            val tint = if (canContinue) VoiidColor.primary else VoiidColor.textSecondary
                            Icon(Icons.Outlined.Link, null, tint = tint, modifier = Modifier.size(12.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("voiid.app/c/${handle.ifEmpty { "…" }}", style = VoiidFont.rounded(12), color = tint,
                                 maxLines = 1, modifier = Modifier.weight(1f))
                            Text("Edit", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.primary,
                                 modifier = Modifier.softClickable { haptics.tap(); customHandle = handle }.padding(4.dp))
                        }
                    } else {
                        Row(
                            Modifier.fillMaxWidth()
                                .clip(RoundedCornerShape(VoiidRadius.md))
                                .background(VoiidColor.fieldFill)
                                .border(1.dp, if (showsHandleProblem) VoiidColor.error.copy(alpha = 0.7f) else VoiidColor.fieldBorder,
                                        RoundedCornerShape(VoiidRadius.md))
                                .padding(horizontal = 12.dp, vertical = 11.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("voiid.app/c/", style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
                            BasicTextField(
                                value = customHandle ?: "",
                                onValueChange = { customHandle = CommunityHandle.sanitise(it) },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None,
                                                                  autoCorrectEnabled = false,
                                                                  keyboardType = KeyboardType.Ascii),
                                textStyle = VoiidFont.rounded(14, FontWeight.SemiBold).merge(TextStyle(color = VoiidColor.textPrimary)),
                                modifier = Modifier.weight(1f),
                            )
                            if (availability == HandleAvailability.AVAILABLE && handleProblem == null) {
                                Icon(Icons.Filled.CheckCircle, "Address available", tint = VoiidColor.success,
                                     modifier = Modifier.size(15.dp))
                                Spacer(Modifier.width(6.dp))
                            }
                            Text("${handle.length}/${CommunityHandle.MAX_LENGTH}", style = VoiidFont.rounded(11),
                                 color = VoiidColor.textSecondary)
                        }
                    }
                    if (showsHandleProblem && handleProblem != null) {
                        Row(Modifier.padding(top = 5.dp, start = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.ErrorOutline, null, tint = VoiidColor.error, modifier = Modifier.size(13.dp))
                            Spacer(Modifier.width(4.dp))
                            Text(handleProblem, style = VoiidFont.rounded(12), color = VoiidColor.error)
                        }
                    }

                    // ── Category ──
                    Spacer(Modifier.height(20.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Category", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = VoiidColor.textSecondary)
                        Spacer(Modifier.width(6.dp))
                        Text("Optional", style = VoiidFont.rounded(11), color = VoiidColor.textSecondary.copy(alpha = 0.8f))
                    }
                    Spacer(Modifier.height(9.dp))
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        communityCategories.forEach { option ->
                            val selected = category == option
                            Box(
                                Modifier
                                    .clip(RoundedCornerShape(999.dp))
                                    .background(if (selected) VoiidColor.primary else VoiidColor.surfaceCard)
                                    .border(1.dp, if (selected) Color.Transparent else VoiidColor.fieldBorder, RoundedCornerShape(999.dp))
                                    // Tapping the chosen one again clears it — optional means undoable.
                                    .softClickable { haptics.selection(); category = if (selected) "" else option }
                                    .padding(horizontal = 14.dp, vertical = 9.dp),
                            ) {
                                Text(option, style = VoiidFont.rounded(13, FontWeight.SemiBold),
                                     color = if (selected) VoiidColor.textOnPrimary else VoiidColor.textPrimary)
                            }
                        }
                    }
                }

                CreateStep.JOINING -> {
                    Text(trimmedName, style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textSecondary, maxLines = 1)
                    Spacer(Modifier.height(4.dp))
                    Text("Who can join?", style = VoiidFont.rounded(24, FontWeight.Bold), color = VoiidColor.textPrimary)
                    Text("You can change this any time in settings.", style = VoiidFont.rounded(14),
                         color = VoiidColor.textSecondary, modifier = Modifier.padding(top = 4.dp))
                    Spacer(Modifier.height(18.dp))

                    policyOptions.forEach { policy ->
                        val selected = joinPolicy == policy.id
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(VoiidRadius.lg))
                                .background(VoiidColor.surfaceCard)
                                .border(if (selected) 1.5.dp else 1.dp,
                                        if (selected) VoiidColor.primary else VoiidColor.fieldBorder,
                                        RoundedCornerShape(VoiidRadius.lg))
                                .softClickable(enabled = !creating) { haptics.selection(); joinPolicy = policy.id }
                                .padding(16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(
                                Modifier.size(42.dp).clip(CircleShape)
                                    .background(if (selected) VoiidColor.primary else VoiidColor.accentTint),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(policy.icon, null, tint = if (selected) VoiidColor.textOnPrimary else VoiidColor.primary,
                                     modifier = Modifier.size(19.dp))
                            }
                            Spacer(Modifier.width(14.dp))
                            Column(Modifier.weight(1f)) {
                                Text(policy.title, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                                Text(policy.detail, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                            }
                            Spacer(Modifier.width(8.dp))
                            Icon(if (selected) Icons.Filled.CheckCircle else Icons.Outlined.Circle, null,
                                 tint = if (selected) VoiidColor.primary else VoiidColor.fieldBorder,
                                 modifier = Modifier.size(21.dp))
                        }
                        Spacer(Modifier.height(10.dp))
                    }

                    Spacer(Modifier.height(8.dp))
                    Row(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(VoiidRadius.md))
                            .background(VoiidColor.accentTint)
                            .padding(12.dp),
                    ) {
                        Icon(Icons.Filled.CheckCircle, null, tint = VoiidColor.primary, modifier = Modifier.size(17.dp))
                        Spacer(Modifier.width(11.dp))
                        Column {
                            Text("You can finish the details later", style = VoiidFont.rounded(13, FontWeight.SemiBold),
                                 color = VoiidColor.textPrimary)
                            Text("Your community is ready after this. Add a description, Spaces, rules and invites from its Home whenever you like.",
                                 style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
                        }
                    }
                }
            }
            createError?.let {
                Spacer(Modifier.height(12.dp))
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            }
            Spacer(Modifier.height(16.dp))
        }

        Box(
            Modifier.fillMaxWidth().background(VoiidColor.surfaceCard).navigationBarsPadding().padding(16.dp),
        ) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(52.dp)
                    .alpha(if (canContinue && !creating) 1f else 0.45f)
                    .clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(VoiidColor.primary)
                    .softClickable(enabled = canContinue && !creating) {
                        haptics.tap()
                        if (step == CreateStep.IDENTITY) step = CreateStep.JOINING else createNow()
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    when {
                        creating -> "Creating…"
                        step == CreateStep.IDENTITY -> "Continue"
                        else -> "Create community"
                    },
                    style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textOnPrimary,
                )
            }
        }
    }
}

@Composable
private fun FieldBox(content: @Composable () -> Unit) {
    Box(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.md))
            .padding(horizontal = 14.dp, vertical = 14.dp),
    ) { content() }
}

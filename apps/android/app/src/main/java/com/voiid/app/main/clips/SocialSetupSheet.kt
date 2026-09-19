package com.voiid.app.main.clips

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.voiid.app.model.SocialStore
import com.voiid.app.net.ApiError
import com.voiid.app.net.SocialService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.launch

/**
 * THE GATE — a creator profile is required before a first clip can be posted, and this is
 * where it gets created: on demand, at first post, not at signup (see 029's header for why
 * manufacturing a public identity for every account is both a privacy and a namespace
 * problem). Mirrors iOS `SocialSetupSheet.swift`.
 *
 * ── THIS IS PUBLIC, AND THE COPY SAYS SO ─────────────────────────────────────────
 * A creator handle is BROADCAST IDENTITY: visible to strangers, attached to every clip.
 * It is NOT the chat @username, which is half a private credential (username + PIN opens a
 * message request). They share one namespace so that a single @name can never mean two
 * different people, but they are different things and the sheet must not imply otherwise.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SocialSetupSheet(
    creators: SocialStore,
    onCreated: (SocialService.Profile) -> Unit,
    onDismiss: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()

    var handle by remember { mutableStateOf("") }
    var displayName by remember { mutableStateOf("") }
    var bio by remember { mutableStateOf("") }
    var submitting by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    // ── THE THREE STEPS, matching iOS SocialSetupSheet.swift ────────────────────
    // Identity was all this sheet ever collected. Age is what the under-18 protections
    // read, and the guidelines are the agreement to POST — the signup Terms cover the
    // account, not publishing to strangers (Apple 1.2 wants a EULA people actually accept).
    var step by remember { mutableIntStateOf(1) }
    var birthYear by remember { mutableStateOf("") }
    var birthMonth by remember { mutableStateOf("") }
    var birthDay by remember { mutableStateOf("") }
    var interests by remember { mutableStateOf(setOf<String>()) }
    var acceptedGuidelines by remember { mutableStateOf(false) }

    val birthDate: String? = remember(birthYear, birthMonth, birthDay) {
        val y = birthYear.toIntOrNull(); val m = birthMonth.toIntOrNull(); val d = birthDay.toIntOrNull()
        if (y == null || m == null || d == null) null
        else if (y < 1900 || m !in 1..12 || d !in 1..31) null
        else "%04d-%02d-%02d".format(y, m, d)
    }

    // Whole years, the same arithmetic the server's age predicate uses.
    val age: Int? = remember(birthDate) {
        birthDate?.let {
            runCatching {
                val b = java.time.LocalDate.parse(it)
                java.time.Period.between(b, java.time.LocalDate.now()).years
            }.getOrNull()
        }
    }
    val isMinor = (age ?: 99) < 18

    val state = creators.handleState
    val normalized = handle.trim().lowercase()

    // Submission needs only a well-formed handle. The availability check is ADVISORY —
    // blocking on Available would strand the user whenever the check itself failed, and the
    // create call re-validates under the real unique constraint regardless.
    val identityOk = SocialService.isWellFormed(normalized) &&
        state !is SocialStore.HandleState.Taken
    // 13 is the floor for a profile at all; under-18 is allowed through and restricted
    // rather than excluded, which is what DPDP asks for.
    val ageOk = age != null && age >= 13
    val interestsOk = interests.size >= 3 && acceptedGuidelines

    val canSubmit = !submitting && when (step) {
        1 -> identityOk
        2 -> ageOk
        else -> interestsOk
    }

    LaunchedEffect(Unit) { creators.resetHandleState() }

    com.voiid.app.ui.components.VoiidSheet(
        visible = true,
        onDismiss = { if (!submitting) onDismiss() },
        detents = listOf(com.voiid.app.ui.components.VoiidDetent.Medium),
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = VoiidSpacing.md)
                .padding(bottom = VoiidSpacing.lg)
                .imePadding()
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
        ) {
            Text(
                "Step $step of 3",
                style = VoiidFont.rounded(12, FontWeight.SemiBold),
                color = VoiidColor.textSecondary,
            )

            if (step == 1) {
            Text(
                "Create your Social Profile",
                style = VoiidFont.rounded(24, FontWeight.Bold),
                color = VoiidColor.textPrimary,
            )
            Text(
                "One public identity for Clips, Games and Communities. This is how people find you.",
                style = VoiidFont.rounded(15),
                color = VoiidColor.textSecondary,
            )

            // ── Handle ────────────────────────────────────────────────────────────
            val borderColor = when (state) {
                is SocialStore.HandleState.Available -> VoiidColor.success
                is SocialStore.HandleState.Taken,
                is SocialStore.HandleState.BadFormat -> VoiidColor.error
                else -> VoiidColor.fieldBorder
            }
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(61.dp)
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.fieldFill)
                    .border(1.dp, borderColor, RoundedCornerShape(VoiidRadius.md))
                    .padding(horizontal = VoiidSpacing.md),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("@", style = VoiidFont.rounded(17), color = VoiidColor.textSecondary)
                Box(Modifier.weight(1f).padding(start = VoiidSpacing.xs)) {
                    BasicTextField(
                        value = handle,
                        // Lowercased as you type rather than at submit, so what the field
                        // shows is exactly what gets reserved — handles are case-insensitive
                        // server-side.
                        onValueChange = {
                            handle = it.lowercase()
                            errorText = null
                            creators.checkHandle(handle)
                        },
                        singleLine = true,
                        textStyle = VoiidFont.rounded(17).copy(color = VoiidColor.textPrimary),
                        cursorBrush = SolidColor(VoiidColor.primary),
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None,
                            autoCorrectEnabled = false,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (handle.isEmpty()) {
                        Text("handle", style = VoiidFont.rounded(17), color = VoiidColor.placeholder)
                    }
                }
                when (state) {
                    is SocialStore.HandleState.Checking ->
                        CircularProgressIndicator(
                            Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = VoiidColor.textSecondary,
                        )
                    is SocialStore.HandleState.Available ->
                        Icon(Icons.Filled.CheckCircle, null,
                            tint = VoiidColor.success, modifier = Modifier.size(20.dp))
                    is SocialStore.HandleState.Taken,
                    is SocialStore.HandleState.BadFormat ->
                        Icon(Icons.Filled.Cancel, null,
                            tint = VoiidColor.error, modifier = Modifier.size(20.dp))
                    else -> Unit
                }
            }

            val hint = when (state) {
                is SocialStore.HandleState.Available -> "@$normalized is available."
                is SocialStore.HandleState.Taken -> "That handle is taken."
                is SocialStore.HandleState.Checking -> "Checking…"
                is SocialStore.HandleState.Failed -> state.message
                else ->
                    "3–20 characters. Letters, numbers and underscores, starting with a letter."
            }
            val hintColor = when (state) {
                is SocialStore.HandleState.Available -> VoiidColor.success
                is SocialStore.HandleState.Taken,
                is SocialStore.HandleState.BadFormat -> VoiidColor.error
                else -> VoiidColor.textSecondary
            }
            Text(hint, style = VoiidFont.rounded(12), color = hintColor)

            LabelledField("Display name", displayName, "Optional") { displayName = it }
            LabelledField("Bio", bio, "Optional") { bio = it }

            // Clips are not end-to-end encrypted, and §6 of the rebuild doc is explicit that
            // the UI must say so plainly rather than let someone assume Clips behaves like
            // their chats.
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.fieldFill.copy(alpha = 0.6f))
                    .padding(VoiidSpacing.sm),
                horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
            ) {
                Icon(Icons.Filled.Public, null,
                    tint = VoiidColor.textSecondary, modifier = Modifier.size(16.dp))
                Text(
                    "Your handle, name and photo are public. They appear on your Clips, " +
                        "your community posts and your games, and are not end-to-end " +
                        "encrypted. Your messages, calls and locations stay encrypted.",
                    style = VoiidFont.rounded(12),
                    color = VoiidColor.textSecondary,
                )
            }

            }

            if (step == 2) {
                Text(
                    "When is your birthday?",
                    style = VoiidFont.rounded(24, FontWeight.Bold),
                    color = VoiidColor.textPrimary,
                )
                Text(
                    "This sets your safety protections. It is never shown on your profile " +
                        "and never shared with anyone.",
                    style = VoiidFont.rounded(15),
                    color = VoiidColor.textSecondary,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                    Box(Modifier.weight(1f)) {
                        LabelledField("Day", birthDay, "DD") {
                            birthDay = it.filter(Char::isDigit).take(2)
                        }
                    }
                    Box(Modifier.weight(1f)) {
                        LabelledField("Month", birthMonth, "MM") {
                            birthMonth = it.filter(Char::isDigit).take(2)
                        }
                    }
                    Box(Modifier.weight(1.3f)) {
                        LabelledField("Year", birthYear, "YYYY") {
                            birthYear = it.filter(Char::isDigit).take(4)
                        }
                    }
                }
                if (age != null && age < 13) {
                    Text(
                        "You need to be 13 or older to have a Social Profile.",
                        style = VoiidFont.rounded(13), color = VoiidColor.error,
                    )
                } else if (age != null && isMinor) {
                    // Told, not applied silently: the UK Children's Code wants the protection
                    // legible, and a restriction a teenager discovers by accident is the one
                    // they work around.
                    Text(
                        "Teen Safe mode — your feed won't be personalised from your activity, " +
                            "and you won't see targeted ads.",
                        style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                    )
                }
                Text(
                    "We do not sell your data, we do not share your date of birth, and we do " +
                        "not use your clips or messages to train anything.",
                    style = VoiidFont.rounded(12), color = VoiidColor.textSecondary,
                )
            }

            if (step == 3) {
                Text(
                    "What do you want to see?",
                    style = VoiidFont.rounded(24, FontWeight.Bold),
                    color = VoiidColor.textPrimary,
                )
                Text(
                    "Pick at least 3. You can change these any time.",
                    style = VoiidFont.rounded(15),
                    color = VoiidColor.textSecondary,
                )
                androidx.compose.foundation.layout.FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.xs),
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.xs),
                ) {
                    SOCIAL_TOPICS.forEach { (id, label) ->
                        val on = interests.contains(id)
                        Box(
                            Modifier
                                .clip(RoundedCornerShape(VoiidRadius.md))
                                .background(if (on) VoiidColor.primary else VoiidColor.fieldFill)
                                .border(
                                    1.dp,
                                    if (on) VoiidColor.primary else VoiidColor.fieldBorder,
                                    RoundedCornerShape(VoiidRadius.md),
                                )
                                .clickable {
                                    haptics.tap()
                                    interests = if (on) interests - id else interests + id
                                }
                                .padding(horizontal = VoiidSpacing.md, vertical = 10.dp),
                        ) {
                            Text(
                                label,
                                style = VoiidFont.rounded(14, FontWeight.Medium),
                                color = if (on) VoiidColor.textOnPrimary else VoiidColor.textPrimary,
                            )
                        }
                    }
                }

                // The agreement to POST. The signup Terms cover the account; this covers
                // publishing to strangers, which Apple 1.2 requires people actually accept.
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(VoiidRadius.md))
                        .background(VoiidColor.fieldFill.copy(alpha = 0.6f))
                        .clickable {
                            haptics.tap()
                            acceptedGuidelines = !acceptedGuidelines
                        }
                        .padding(VoiidSpacing.sm),
                    horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                ) {
                    Icon(
                        if (acceptedGuidelines) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                        null,
                        tint = if (acceptedGuidelines) VoiidColor.primary else VoiidColor.textSecondary,
                        modifier = Modifier.size(20.dp),
                    )
                    Text(
                        "I agree to the Community Guidelines. No harassment, hate, sexual " +
                            "content involving minors, or violent or illegal material. " +
                            "Accounts that post it are removed.",
                        style = VoiidFont.rounded(12),
                        color = VoiidColor.textSecondary,
                    )
                }
            }

            errorText?.let {
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            }

            Box(
                Modifier
                    .fillMaxWidth()
                    .height(64.dp)
                    .clip(RoundedCornerShape(VoiidRadius.lg))
                    .background(
                        if (canSubmit) VoiidColor.primary
                        else VoiidColor.primary.copy(alpha = 0.5f)
                    )
                    .let { m ->
                        // A plain clickable, not bouncyClickable — that helper scales to 1.4x
                        // for emoji reactions and would blow up a full-width button.
                        if (!canSubmit) m else m.clickable {
                            haptics.tap()
                            if (step < 3) { step += 1; errorText = null; return@clickable }
                            submitting = true
                            errorText = null
                            scope.launch {
                                try {
                                    val profile = creators.createProfile(
                                        handle = normalized,
                                        displayName = displayName.trim().ifEmpty { null },
                                        bio = bio.trim().ifEmpty { null },
                                        linkUrl = null,
                                        birthDate = birthDate,
                                        interests = interests.toList().sorted(),
                                    )
                                    onCreated(profile)
                                    onDismiss()
                                } catch (e: ApiError.Http) {
                                    // 409 is the race this sheet cannot prevent: the advisory
                                    // check said free, and somebody took the name in between.
                                    // Surfaced on the field, not as a generic failure, so the
                                    // fix (pick another) is obvious.
                                    when (e.status) {
                                        409 -> {
                                            creators.markHandleTaken()
                                            errorText = "That handle was just taken. Try another."
                                        }
                                        else -> errorText = e.message
                                    }
                                } catch (e: Exception) {
                                    errorText = e.message ?: "Couldn't create your profile."
                                } finally {
                                    submitting = false
                                }
                            }
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (submitting) "Creating…"
                    else if (step < 3) "Continue"
                    else "Enter Voiid Clips",
                    style = VoiidFont.rounded(17, FontWeight.SemiBold),
                    color = VoiidColor.textOnPrimary,
                )
            }
        }
    }
}

@Composable
private fun LabelledField(
    label: String,
    value: String,
    placeholder: String,
    onValueChange: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.xs)) {
        Text(label, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        Box(
            Modifier
                .fillMaxWidth()
                .height(61.dp)
                .clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidColor.fieldFill)
                .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.md))
                .padding(horizontal = VoiidSpacing.md),
            contentAlignment = Alignment.CenterStart,
        ) {
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                singleLine = true,
                textStyle = VoiidFont.rounded(17).copy(color = VoiidColor.textPrimary),
                cursorBrush = SolidColor(VoiidColor.primary),
                modifier = Modifier.fillMaxWidth(),
            )
            if (value.isEmpty()) {
                Text(placeholder, style = VoiidFont.rounded(17), color = VoiidColor.placeholder)
            }
        }
    }
}

/** The topics that seed the recommendation feed. Same ids and order as iOS `ClipTopic.all`. */
private val SOCIAL_TOPICS: List<Pair<String, String>> = listOf(
    "gaming" to "Gaming",
    "tech" to "Tech & AI",
    "comedy" to "Comedy",
    "cricket" to "Cricket & Sport",
    "music" to "Music",
    "travel" to "Travel",
    "fashion" to "Fashion",
    "food" to "Food",
    "design" to "Design & Art",
    "anime" to "Anime & Film",
    "finance" to "Finance",
    "motors" to "Cars & Speed",
)

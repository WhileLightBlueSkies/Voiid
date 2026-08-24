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
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.voiid.app.model.CreatorStore
import com.voiid.app.net.ApiError
import com.voiid.app.net.CreatorService
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
 * problem). Mirrors iOS `CreatorHandleSheet.swift`.
 *
 * ── THIS IS PUBLIC, AND THE COPY SAYS SO ─────────────────────────────────────────
 * A creator handle is BROADCAST IDENTITY: visible to strangers, attached to every clip.
 * It is NOT the chat @username, which is half a private credential (username + PIN opens a
 * message request). They share one namespace so that a single @name can never mean two
 * different people, but they are different things and the sheet must not imply otherwise.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CreatorHandleSheet(
    creators: CreatorStore,
    onCreated: (CreatorService.Profile) -> Unit,
    onDismiss: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val scope = rememberCoroutineScope()

    var handle by remember { mutableStateOf("") }
    var displayName by remember { mutableStateOf("") }
    var bio by remember { mutableStateOf("") }
    var submitting by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    val state = creators.handleState
    val normalized = handle.trim().lowercase()

    // Submission needs only a well-formed handle. The availability check is ADVISORY —
    // blocking on Available would strand the user whenever the check itself failed, and the
    // create call re-validates under the real unique constraint regardless.
    val canSubmit = !submitting &&
        CreatorService.isWellFormed(normalized) &&
        state !is CreatorStore.HandleState.Taken

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
                "Pick a name for your clips",
                style = VoiidFont.rounded(24, FontWeight.Bold),
                color = VoiidColor.textPrimary,
            )
            Text(
                "This is how people find and follow you on Clips.",
                style = VoiidFont.rounded(15),
                color = VoiidColor.textSecondary,
            )

            // ── Handle ────────────────────────────────────────────────────────────
            val borderColor = when (state) {
                is CreatorStore.HandleState.Available -> VoiidColor.success
                is CreatorStore.HandleState.Taken,
                is CreatorStore.HandleState.BadFormat -> VoiidColor.error
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
                    is CreatorStore.HandleState.Checking ->
                        CircularProgressIndicator(
                            Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = VoiidColor.textSecondary,
                        )
                    is CreatorStore.HandleState.Available ->
                        Icon(Icons.Filled.CheckCircle, null,
                            tint = VoiidColor.success, modifier = Modifier.size(20.dp))
                    is CreatorStore.HandleState.Taken,
                    is CreatorStore.HandleState.BadFormat ->
                        Icon(Icons.Filled.Cancel, null,
                            tint = VoiidColor.error, modifier = Modifier.size(20.dp))
                    else -> Unit
                }
            }

            val hint = when (state) {
                is CreatorStore.HandleState.Available -> "@$normalized is available."
                is CreatorStore.HandleState.Taken -> "That handle is taken."
                is CreatorStore.HandleState.Checking -> "Checking…"
                is CreatorStore.HandleState.Failed -> state.message
                else ->
                    "3–20 characters. Letters, numbers and underscores, starting with a letter."
            }
            val hintColor = when (state) {
                is CreatorStore.HandleState.Available -> VoiidColor.success
                is CreatorStore.HandleState.Taken,
                is CreatorStore.HandleState.BadFormat -> VoiidColor.error
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
                    "Your handle, profile and clips are public and are not end-to-end " +
                        "encrypted. Your messages, calls and locations stay encrypted.",
                    style = VoiidFont.rounded(12),
                    color = VoiidColor.textSecondary,
                )
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
                            submitting = true
                            errorText = null
                            scope.launch {
                                try {
                                    val profile = creators.createProfile(
                                        handle = normalized,
                                        displayName = displayName.trim().ifEmpty { null },
                                        bio = bio.trim().ifEmpty { null },
                                        linkUrl = null,
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
                    if (submitting) "Creating…" else "Create profile",
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

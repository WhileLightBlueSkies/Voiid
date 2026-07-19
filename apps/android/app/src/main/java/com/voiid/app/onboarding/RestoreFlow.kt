package com.voiid.app.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.main.BackupButton
import com.voiid.app.main.BackupScaffold
import com.voiid.app.main.BackupSecondaryButton
import com.voiid.app.main.PinEntryScreen
import com.voiid.app.model.AppSession
import com.voiid.app.net.BackupManager
import com.voiid.app.net.BackupService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.noRippleClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * Post-login restore, shown to a returning user whose account HAS a server backup
 * (see OtpScreen). Two unlock paths — numeric PIN or 24-word recovery phrase — then
 * download → decrypt → import the chats and finish onboarding. Always skippable.
 */
private enum class RestoreStep { LANDING, PIN, PHRASE }

@Composable
fun RestoreFlow(
    session: AppSession,
    meta: BackupService.BackupMeta,
    onDone: () -> Unit,
    onSkip: () -> Unit,
) {
    val context = LocalContext.current
    val manager = remember { BackupManager(context) }
    val scope = rememberCoroutineScope()

    var step by remember { mutableStateOf(RestoreStep.LANDING) }
    var pin by remember { mutableStateOf("") }
    var phrase by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    fun finish() { onDone() }

    fun handleOutcome(outcome: BackupManager.RestoreOutcome) {
        when (outcome) {
            is BackupManager.RestoreOutcome.Success -> finish()
            is BackupManager.RestoreOutcome.WrongPin -> { error = "Incorrect PIN. Please try again."; pin = "" }
            is BackupManager.RestoreOutcome.NoRecoveryKey -> error = "No recovery key found for this account."
            is BackupManager.RestoreOutcome.Locked -> {
                val secs = outcome.retryAfterSeconds
                error = if (secs != null) "Too many attempts. Try again in ${formatRetry(secs)}."
                else "Too many attempts. Please try again later."
            }
        }
    }

    when (step) {
        RestoreStep.LANDING -> RestoreLanding(
            meta = meta,
            onBack = onSkip,
            onEnterPin = { error = null; step = RestoreStep.PIN },
            onEnterPhrase = { error = null; step = RestoreStep.PHRASE },
            onSkip = onSkip,
        )
        RestoreStep.PIN -> PinEntryScreen(
            title = "Enter your PIN",
            subtitle = "Enter the backup PIN you set to restore your chats.",
            value = pin, onValueChange = { pin = it; error = null },
            error = error, busy = busy, cta = if (busy) "Restoring…" else "Restore",
            ctaEnabled = pin.length in 4..8 && !busy,
            onBack = { step = RestoreStep.LANDING; error = null },
            onSubmit = {
                busy = true; error = null
                scope.launch {
                    try {
                        handleOutcome(manager.restoreWithPin(pin))
                    } catch (e: Exception) {
                        error = e.message ?: "Couldn't restore. Please try again."
                    }
                    busy = false
                }
            },
            footer = {
                Text("Use recovery phrase instead",
                    style = VoiidFont.rounded(14, FontWeight.Medium), color = VoiidColor.primary,
                    modifier = Modifier.noRippleClickable { error = null; step = RestoreStep.PHRASE })
            },
        )
        RestoreStep.PHRASE -> PhraseEntryScreen(
            value = phrase,
            onValueChange = { phrase = it; error = null },
            error = error,
            busy = busy,
            onBack = { step = RestoreStep.LANDING; error = null },
            onSubmit = {
                busy = true; error = null
                scope.launch {
                    try {
                        handleOutcome(manager.restoreWithPhrase(phrase))
                    } catch (e: Exception) {
                        error = e.message ?: "Invalid recovery phrase."
                    }
                    busy = false
                }
            },
        )
    }
}

@Composable
private fun RestoreLanding(
    meta: BackupService.BackupMeta,
    onBack: () -> Unit,
    onEnterPin: () -> Unit,
    onEnterPhrase: () -> Unit,
    onSkip: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    BackupScaffold(title = "Restore chats", onBack = onBack) {
        Spacer(Modifier.height(8.dp))
        Text(
            "We found an encrypted backup for this account. Restore your chats with your PIN " +
                "or 24-word recovery phrase.",
            style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
        )
        Spacer(Modifier.height(20.dp))
        Text("Last backup: ${formatUpdatedAt(meta.updated_at)} · ${formatSize(meta.size_bytes)}",
            style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        Spacer(Modifier.height(28.dp))
        BackupButton("Enter PIN", enabled = true, onClick = onEnterPin)
        Spacer(Modifier.height(12.dp))
        BackupSecondaryButton("Enter recovery phrase", onClick = onEnterPhrase)
        Spacer(Modifier.height(20.dp))
        Text("Skip for now", style = VoiidFont.rounded(14, FontWeight.Medium), color = VoiidColor.textSecondary,
            modifier = Modifier.noRippleClickable { haptics.tap(); onSkip() })
    }
}

@Composable
private fun PhraseEntryScreen(
    value: String,
    onValueChange: (String) -> Unit,
    error: String?,
    busy: Boolean,
    onBack: () -> Unit,
    onSubmit: () -> Unit,
) {
    val shape = RoundedCornerShape(VoiidRadius.lg)
    val wordCount = value.trim().split(Regex("\\s+")).filter { it.isNotBlank() }.size
    BackupScaffold(title = "Recovery phrase", onBack = onBack) {
        Spacer(Modifier.height(8.dp))
        Text("Enter your 24-word recovery phrase, separated by spaces.",
            style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
        Spacer(Modifier.height(20.dp))
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            textStyle = VoiidFont.rounded(16).merge(TextStyle(color = VoiidColor.textPrimary)),
            cursorBrush = SolidColor(VoiidColor.primary),
            modifier = Modifier.fillMaxWidth().heightIn(min = 120.dp).clip(shape)
                .background(VoiidColor.fieldFill).border(1.dp, VoiidColor.fieldBorder, shape).padding(16.dp),
            decorationBox = { inner ->
                if (value.isEmpty()) {
                    Text("word1 word2 word3 …", style = VoiidFont.rounded(16), color = VoiidColor.placeholder)
                }
                inner()
            },
        )
        Spacer(Modifier.height(8.dp))
        Text("$wordCount / 24 words", style = VoiidFont.rounded(12),
            color = if (wordCount == 24) VoiidColor.success else VoiidColor.textSecondary)
        error?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
        }
        Spacer(Modifier.height(24.dp))
        BackupButton(if (busy) "Restoring…" else "Restore", enabled = wordCount == 24 && !busy, onClick = onSubmit)
    }
}

private fun formatSize(bytes: Long): String = when {
    bytes <= 0 -> "—"
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> "${bytes / 1024} KB"
    else -> String.format("%.1f MB", bytes / (1024.0 * 1024.0))
}

private fun formatUpdatedAt(raw: String?): String {
    if (raw.isNullOrBlank()) return "—"
    return raw.replace('T', ' ').substringBefore('.').substringBefore('+').trim().ifBlank { raw }
}

private fun formatRetry(seconds: Long): String = when {
    seconds < 60 -> "$seconds s"
    seconds < 3600 -> "${seconds / 60} min"
    else -> "${seconds / 3600} h"
}

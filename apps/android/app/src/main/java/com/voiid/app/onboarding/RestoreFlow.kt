package com.voiid.app.onboarding

import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.CloudDownload
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.LockOpen
import androidx.compose.material.icons.outlined.QuestionAnswer
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
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
 * Post-login restore for a returning user whose account HAS a backup (see OtpScreen).
 * Port of iOS `RestoreMessagesView`'s interaction model:
 *
 *   unlock (PIN or 24-word phrase) → [choose source, ONLY when several backups exist]
 *   → staged restoring (five named stages, stage-level Retry/Skip on failure,
 *     a 650ms hold on completion so the finished list is legible).
 *
 * The PIN is taken FIRST and the source chosen second — a user who cannot unlock never sees a
 * list of their own backups. NOTHING is verified at unlock: only the unwrap inside
 * restoreWithPin proves the credential, so a wrong one surfaces on the restoring page.
 *
 * Platform note: destinations are SERVER + Google DRIVE (there is no iCloud on Android).
 */
private const val RESTORE_PIN_MAX = 8

private enum class RestoreStep { UNLOCK, PHRASE, CHOOSE, RESTORING }

private sealed interface Credential {
    data class Pin(val value: String) : Credential
    data class Phrase(val value: String) : Credential
}

/** One restorable destination snapshot. */
private data class RestoreCandidate(
    val source: BackupManager.RestoreSource,
    val title: String,
    val updatedAt: String?,
    val sizeBytes: Long,
    val modifiedEpoch: Long = 0,
)

/// Five named stages rather than a spinner: a single spinner tells the user nothing during a
/// two-minute transfer, while a list that has visibly completed two stages shows progress even
/// while the slow one runs. Mirrors iOS `RestoreStage.all`.
private data class RestoreStage(val id: String, val title: String, val icon: ImageVector)

private val restoreStages = listOf(
    RestoreStage("unlock", "Unlocking your backup", Icons.Outlined.Key),
    RestoreStage("download", "Downloading", Icons.Outlined.CloudDownload),
    RestoreStage("decrypt", "Decrypting on device", Icons.Outlined.LockOpen),
    RestoreStage("merge", "Restoring your chats", Icons.Outlined.QuestionAnswer),
    RestoreStage("keys", "Saving recovery key", Icons.Outlined.Shield),
)

@Composable
fun RestoreFlow(    session: AppSession,
    meta: BackupService.BackupMeta,
    onDone: () -> Unit,
    onSkip: () -> Unit,
) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val manager = remember { BackupManager(context) }
    val scope = rememberCoroutineScope()

    var step by remember { mutableStateOf(RestoreStep.UNLOCK) }
    /** An old PIN-protected copy of the key (pre-S04). Only then is a PIN offered; every
     *  newer backup restores with the recovery phrase alone. Null until the server answers. */
    var legacyPin by remember { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(Unit) {
        // A FAILED check is not a "no". It used to default to false, so a flaky network sent
        // PIN accounts straight to the phrase page with the PIN screen gone. Retry, and if the
        // server still has not answered, keep the PIN screen: it offers the phrase too.
        var legacy: Boolean? = null
        for (attempt in 0 until 3) {
            legacy = manager.hasLegacyPinOrNull()
            if (legacy != null) break
            kotlinx.coroutines.delay(800L * (attempt + 1))
        }
        legacyPin = legacy ?: true
        if (legacy == false && step == RestoreStep.UNLOCK) step = RestoreStep.PHRASE
    }
    var pin by remember { mutableStateOf("") }
    var phrase by remember { mutableStateOf("") }
    var credential by remember { mutableStateOf<Credential?>(null) }
    var source by remember { mutableStateOf(BackupManager.RestoreSource.SERVER) }
    var candidates by remember { mutableStateOf<List<RestoreCandidate>>(emptyList()) }
    var loadingCandidates by remember { mutableStateOf(true) }
    var stageIndex by remember { mutableIntStateOf(0) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    var confirmSkip by remember { mutableStateOf(false) }
    // iOS: one action, dismissed by tapping outside — no Cancel button.
    if (confirmSkip) com.voiid.app.ui.components.VoiidDialog(
        onDismissRequest = { confirmSkip = false },
        title = "Continue without restoring?",
        body = "Previous chats will not be restored on this device. Your saved backups stay in their current locations.",
        confirmLabel = "Continue without restoring",
        onConfirm = { confirmSkip = false; onSkip() },
        cancelLabel = null,
    )
    fun finish() = onDone()

    // Load all available destinations; newest first. Server is checked directly; Drive joins
    // the list when an account is already signed in (otherwise it can be added on the choose
    // page). An empty result is reachable (network dropped between the OTP check and here) and
    // is shown honestly rather than as a single unusable row.
    suspend fun loadCandidates(): List<RestoreCandidate> {
        val found = mutableListOf<RestoreCandidate>()
        runCatching { manager.fetchMeta() }.getOrNull()?.let { m ->
            found += RestoreCandidate(
                BackupManager.RestoreSource.SERVER, "Voiid server",
                formatUpdatedAt(m.updated_at), m.size_bytes,
                runCatching { java.time.Instant.parse(m.updated_at).toEpochMilli() }.getOrDefault(0),
            )
        }
        manager.fetchDriveMeta()?.let { d ->
            found += RestoreCandidate(
                BackupManager.RestoreSource.DRIVE, "Google Drive",
                formatUpdatedAt(d.modifiedTime), d.sizeBytes,
                runCatching { java.time.Instant.parse(d.modifiedTime).toEpochMilli() }.getOrDefault(0),
            )
        }
        return found.sortedByDescending { it.modifiedEpoch }
    }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        candidates = loadCandidates()
        source = manager.pendingRestoreSource()?.takeIf { saved -> candidates.any { it.source == saved } } ?: candidates.firstOrNull()?.source ?: BackupManager.RestoreSource.SERVER
        loadingCandidates = false
    }

    // Google Sign-In from the choose page adds the Drive destination to the running list.
    val driveSignInLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) {
        scope.launch {
            busy = true; error = null
            candidates = loadCandidates()
            source = candidates.firstOrNull()?.source ?: source
            if (candidates.none { it.source == BackupManager.RestoreSource.DRIVE }) {
                error = "No Google Drive backup found for this account."
            }
            busy = false
        }
    }

    fun begin() {
        if (busy) return
        val cred = credential ?: run { step = RestoreStep.UNLOCK; return }
        error = null
        stageIndex = 0
        step = RestoreStep.RESTORING
        busy = true
        scope.launch {
            try {
                // The visible stages map onto what actually happens: download and decrypt are
                // inside this one call, so the index advances AROUND it rather than pretending
                // to track internals.
                stageIndex = 1
                val outcome = when (cred) {
                    is Credential.Pin -> manager.restoreWithPin(cred.value, source) { stageIndex = it }
                    is Credential.Phrase -> manager.restoreWithPhrase(cred.value, source) { stageIndex = it }
                }
                when (outcome) {
                    is BackupManager.RestoreOutcome.Success -> {
                        stageIndex = restoreStages.size   // every stage complete
                        haptics.success()
                        // A beat on the completed list, so the last stage is legible rather
                        // than flashing past on its way out.
                        kotlinx.coroutines.delay(650)
                        finish()
                    }
                    is BackupManager.RestoreOutcome.WrongPin -> {
                        error = "Wrong PIN. Please try again — attempts are limited."
                        haptics.error()
                        step = RestoreStep.UNLOCK
                    }
                    is BackupManager.RestoreOutcome.NoRecoveryKey -> {
                        error = "No recovery key found for this account."
                        haptics.error()
                        step = RestoreStep.UNLOCK
                    }
                    is BackupManager.RestoreOutcome.Locked -> {
                        val secs = outcome.retryAfterSeconds
                        error = if (secs != null) "Too many attempts. Try again in ${formatRetry(secs)}."
                        else "Too many attempts. Please try again later."
                        haptics.error()
                        step = RestoreStep.UNLOCK
                    }
                }
            } catch (e: Exception) {
                // Download/decrypt/import failure: reported on THIS page with stage-level
                // Retry/Skip, not silently swallowed.
                error = e.message ?: "Couldn't restore right now. Check your connection and try again."
                haptics.error()
            }
            busy = false
        }
    }


    // Hold the credential and move on. When more than one backup exists the user chooses;
    // with zero or one there is no decision to make, so the page is skipped.
    fun unlock(c: Credential) {
        credential = c
        error = null
        step = RestoreStep.CHOOSE
    }

    // Committed dark, like every onboarding screen and like iOS RestoreMessagesView (drawn on
    // VoiidBrand.ground). Without this a light-mode phone got a light restore flow mid-onboarding.
    androidx.compose.runtime.CompositionLocalProvider(com.voiid.app.ui.theme.LocalVoiidDark provides com.voiid.app.ui.theme.LocalVoiidDark.current) {
    when (step) {
        RestoreStep.UNLOCK -> if (legacyPin == null) {
            Box(Modifier.fillMaxSize().background(VoiidColor.background), contentAlignment = Alignment.Center) {
                androidx.compose.material3.CircularProgressIndicator(color = VoiidColor.primary)
            }
        } else RestoreUnlockPage(
            meta = meta,
            pin = pin,
            onPinChange = { pin = it.filter { c -> c in '0'..'9' }.take(RESTORE_PIN_MAX); error = null },
            error = error,
            onSubmit = { unlock(Credential.Pin(pin)) },
            onRecoveryPhrase = { error = null; step = RestoreStep.PHRASE },
            onSkip = { confirmSkip = true },
        )
        RestoreStep.PHRASE -> RestorePhrasePage(
            value = phrase,
            onChange = { phrase = it; error = null },
            error = error,
            onSubmit = { unlock(Credential.Phrase(phrase)) },
            // iOS PhrasePage: "‹ PIN" only when a legacy PIN backup exists; "Skip" always.
            onBack = if (legacyPin == true) ({ error = null; step = RestoreStep.UNLOCK }) else null,
            onSkip = { haptics.tap(); confirmSkip = true },
        )
        RestoreStep.CHOOSE -> RestoreChoosePage(
            candidates = candidates,
            selected = source,
            loading = loadingCandidates,
            busy = busy,
            error = error,
            onSelect = { haptics.selection(); source = it },
            onDriveSignIn = {
                error = null
                driveSignInLauncher.launch(manager.driveSignInClient().signInIntent)
            },
            onRefresh = {
                scope.launch {
                    loadingCandidates = true
                    candidates = loadCandidates()
                    source = candidates.firstOrNull()?.source ?: source
                    loadingCandidates = false
                }
            },
            onRestore = { begin() },
            onSetUpAsNew = { haptics.tap(); confirmSkip = true },
        )
        RestoreStep.RESTORING -> RestoreStagingPage(
            stageIndex = stageIndex,
            sourceTitle = candidates.firstOrNull { it.source == source }?.title ?: "your backup",
            error = error.takeIf { !busy },
            busy = busy,
            onRetry = { begin() },
            onSkip = { haptics.tap(); confirmSkip = true },
        )
    }
    }
}

// MARK: - 1. Unlock (exactly eight digits)

@Composable
private fun RestoreUnlockPage(
    meta: BackupService.BackupMeta,
    pin: String,
    onPinChange: (String) -> Unit,
    error: String?,
    onSubmit: () -> Unit,
    onRecoveryPhrase: () -> Unit,
    onSkip: () -> Unit,
) {
    // iOS RestoreMessagesView.UnlockPage: centred stacked header (no wordmark), a backup
    // summary with its cloud glyph, the PIN field, the "Only you know your PIN" card, the
    // "Forgot your PIN? Use recovery phrase" row, and a footer with the brand button and
    // "Continue without restoring".
    val complete = pin.length == RESTORE_PIN_MAX
    OnbScaffold(showBack = false, onBack = {}) {
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp).padding(top = 24.dp, bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            OnboardingHeader(
                title = OnboardingTitleSpec.Stacked("Welcome back to", "Voiid"),
                blurb = "Enter your Voiid PIN to restore this account.",
                showsWordmark = false,
            )
            Row(Modifier.padding(top = 16.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Outlined.CloudDownload, null, tint = VoiidBrand.lime, modifier = Modifier.size(18.dp))
                Text(
                    if (meta.size_bytes > 0) "Backup from ${formatUpdatedAt(meta.updated_at)} · ${formatSize(meta.size_bytes)}"
                    else "Choose a backup location after entering your PIN.",
                    style = VoiidFont.rounded(14), color = VoiidBrand.textDim,
                )
            }
            Spacer(Modifier.height(24.dp))
            RestorePinField(value = pin, onChange = onPinChange)
            error?.let {
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    modifier = Modifier.padding(top = 8.dp))
            }
            Spacer(Modifier.height(24.dp))
            RestoreNoteCard(Icons.Outlined.Shield, "Only you know your PIN",
                "It never leaves this device. Your backup is decrypted here, so Voiid cannot read it.")
            Row(
                Modifier.padding(top = 24.dp).fillMaxWidth().noRippleClickable { onRecoveryPhrase() },
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Key, null, tint = VoiidBrand.lime, modifier = Modifier.size(17.dp))
                Text("Forgot your PIN?", style = VoiidFont.rounded(15), color = VoiidBrand.textDim)
                Text("Use recovery phrase", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidBrand.lime)
            }
        }
        OnboardingFooter {
            OnboardingKitButton(title = "Continue", enabled = complete, usesBrandGradient = true) { onSubmit() }
            Text("Continue without restoring",
                style = VoiidFont.rounded(15), color = VoiidBrand.textDim,
                modifier = Modifier.align(Alignment.CenterHorizontally).padding(vertical = 8.dp)
                    .noRippleClickable { onSkip() })
        }
    }
}

/** iOS RestoreNoteCard: 46 tinted circle + glyph, 15 semibold title, 12.5 detail, card + hairline. */
@Composable
private fun RestoreNoteCard(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, detail: String) {
    val shape = RoundedCornerShape(VoiidRadius.lg)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(VoiidBrand.card).border(1.dp, VoiidBrand.hairline, shape)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Box(Modifier.size(46.dp).clip(CircleShape).background(VoiidBrand.lime.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = VoiidBrand.lime, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidBrand.text)
            Text(detail, style = VoiidFont.rounded(12.5f), color = VoiidBrand.textDim)
        }
    }
}

/** Six separate masked boxes over one invisible field — mirrors the iOS unlock field. */
@Composable
private fun RestorePinField(value: String, onChange: (String) -> Unit, modifier: Modifier = Modifier) {
    com.voiid.app.main.PinField(value = value, onValueChange = onChange, modifier = modifier)
}

// MARK: - 2. Recovery phrase

@Composable
private fun RestorePhrasePage(
    value: String,
    onChange: (String) -> Unit,
    error: String?,
    onSubmit: () -> Unit,
    onBack: (() -> Unit)?,
    onSkip: () -> Unit,
) {
    val shape = RoundedCornerShape(VoiidRadius.md)
    val wordCount = value.trim().split(Regex("\\s+")).filter { it.isNotBlank() }.size
    OnbScaffold(showBack = false, onBack = {}) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) Text("‹ PIN", style = VoiidFont.rounded(16), color = VoiidColor.primary,
                modifier = Modifier.noRippleClickable { onBack() }.padding(vertical = 8.dp))
            Spacer(Modifier.weight(1f))
            Text("Skip", style = VoiidFont.rounded(16), color = VoiidColor.textSecondary,
                modifier = Modifier.noRippleClickable { onSkip() }.padding(vertical = 8.dp)
                    .semantics { contentDescription = "Continue without restoring" })
        }
        Spacer(Modifier.height(16.dp))
        Text("Enter recovery phrase", style = VoiidFont.rounded(22, FontWeight.SemiBold),
            color = VoiidColor.textPrimary, modifier = Modifier.padding(horizontal = 24.dp))
        Text("Type or paste your 24-word recovery phrase, separated by spaces.",
            style = VoiidFont.rounded(15), color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 24.dp).padding(top = 16.dp))
        Spacer(Modifier.height(16.dp))
        BasicTextField(
            value = value,
            onValueChange = onChange,
            textStyle = VoiidFont.rounded(16).merge(TextStyle(color = VoiidColor.textPrimary)),
            cursorBrush = SolidColor(VoiidColor.primary),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp)
                .height(156.dp).clip(shape)
                .background(VoiidColor.fieldFill).border(1.dp, VoiidColor.fieldBorder, shape)
                .padding(12.dp),
        )
        Spacer(Modifier.height(16.dp))
        Text("$wordCount / 24 words", style = VoiidFont.rounded(12),
            color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 24.dp))
        error?.let {
            Spacer(Modifier.height(8.dp))
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                modifier = Modifier.padding(horizontal = 24.dp))
        }
        Spacer(Modifier.weight(1f))
        com.voiid.app.ui.components.VoiidPrimaryButton(
            title = "Restore",
            enabled = wordCount == 24,
            modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 24.dp),
        ) { onSubmit() }
    }
}

// MARK: - 3. Source choice (only when several backups exist)

@Composable
private fun RestoreChoosePage(
    candidates: List<RestoreCandidate>,
    selected: BackupManager.RestoreSource,
    loading: Boolean,
    busy: Boolean,
    error: String?,
    onSelect: (BackupManager.RestoreSource) -> Unit,
    onDriveSignIn: () -> Unit,
    onRefresh: () -> Unit,
    onRestore: () -> Unit,
    onSetUpAsNew: () -> Unit,
) {
    OnbScaffold(showBack = false, onBack = {}) {
        Spacer(Modifier.height(32.dp))
        Text("Restore your chats", style = VoiidFont.rounded(28, FontWeight.Bold),
            color = VoiidColor.textPrimary, modifier = Modifier.padding(horizontal = 24.dp))
        Text("Choose which backup to restore on this device.",
            style = VoiidFont.rounded(15), color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 24.dp).padding(top = 6.dp))

        Spacer(Modifier.height(24.dp))
        Column(Modifier.verticalScroll(rememberScrollState()).weight(1f, fill = false)) {
            when {
                loading -> Text(
                    "Checking for backups…", style = VoiidFont.rounded(14),
                    color = VoiidColor.textSecondary, modifier = Modifier.padding(horizontal = 24.dp))
                candidates.isEmpty() -> NoteCard(
                    "No backups available right now",
                    "Check your connection, then try again.",
                )
                else -> {
                    candidates.forEach { c ->
                        CandidateCard(
                            candidate = c,
                            isSelected = selected == c.source,
                            isRecommended = c == candidates.firstOrNull(),
                            onClick = { onSelect(c.source) },
                            modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 10.dp),
                        )
                    }
                    Spacer(Modifier.height(12.dp))
                    NoteCard(
                        "Restore the newest one",
                        "Anything created after the backup you choose will not be on this device.",
                    )
                }
            }
                    if (candidates.none { it.source == BackupManager.RestoreSource.DRIVE }) {
                        Text("Add Google Drive backup",
                            style = VoiidFont.rounded(14, FontWeight.Medium), color = VoiidColor.primary,
                            modifier = Modifier.padding(horizontal = 24.dp).padding(top = 4.dp)
                                .noRippleClickable { onDriveSignIn() })
                    }
            Text("Check again", style = VoiidFont.rounded(14), color = VoiidColor.accentInk,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp).noRippleClickable { if (!loading && !busy) onRefresh() })
            error?.let {
                Spacer(Modifier.height(10.dp))
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                    modifier = Modifier.padding(horizontal = 24.dp))
            }
        }

        Spacer(Modifier.weight(1f))
        OnbAccentButton(
            title = "Restore",
            enabled = candidates.isNotEmpty() && !busy,
            modifier = Modifier.padding(horizontal = 24.dp),
        ) { onRestore() }
        Text("Continue without restoring",
            style = VoiidFont.rounded(15), color = VoiidColor.textSecondary,
            modifier = Modifier.padding(top = 12.dp, bottom = 32.dp).noRippleClickable { onSetUpAsNew() })
    }
}

@Composable
private fun CandidateCard(
    candidate: RestoreCandidate,
    isSelected: Boolean,
    isRecommended: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(16.dp)
    Row(
        modifier
            .clip(shape)
            .background(VoiidColor.fieldFill)
            .border(if (isSelected) 1.5.dp else 1.dp,
                if (isSelected) VoiidColor.primary else VoiidColor.fieldBorder, shape)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) { onClick() }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(46.dp).clip(CircleShape).background(VoiidColor.primary.copy(alpha = 0.10f)),
            contentAlignment = Alignment.Center) {
            Icon(Icons.Outlined.CloudDownload, null, tint = VoiidColor.primary, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(candidate.title, style = VoiidFont.rounded(15, FontWeight.SemiBold),
                     color = VoiidColor.textPrimary)
                if (isRecommended) {
                    Text("Newest", style = VoiidFont.rounded(11, FontWeight.SemiBold),
                         color = Color.White,
                         modifier = Modifier.clip(RoundedCornerShape(999.dp))
                             .background(VoiidColor.primary).padding(horizontal = 7.dp, vertical = 2.dp))
                }
            }
            Text("${candidate.updatedAt ?: "—"} · ${formatSize(candidate.sizeBytes)}",
                style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
        }
        Box(
            Modifier.size(20.dp).clip(CircleShape).border(
                if (isSelected) 6.dp else 1.5.dp,
                if (isSelected) VoiidColor.primary else VoiidColor.textSecondary.copy(alpha = 0.6f),
                CircleShape,
            )
        )
    }
}

@Composable
private fun NoteCard(title: String, detail: String, modifier: Modifier = Modifier) {
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(14.dp))
            .padding(14.dp),
    ) {
        Text(title, style = VoiidFont.rounded(14, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Text(detail, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
            modifier = Modifier.padding(top = 2.dp))
    }
}

// MARK: - 4. Staged restoring

@Composable
private fun RestoreStagingPage(
    stageIndex: Int,
    sourceTitle: String,
    error: String?,
    busy: Boolean,
    onRetry: () -> Unit,
    onSkip: () -> Unit,
) {
    val failed = error != null
    OnbScaffold(showBack = false, onBack = {}) {
        Spacer(Modifier.height(40.dp))
        Text("Restoring your Voiid", style = VoiidFont.rounded(28, FontWeight.Bold),
            color = VoiidColor.textPrimary, modifier = Modifier.padding(horizontal = 24.dp))
        Text("Keep the app open. This can take a few minutes on a large backup.",
            style = VoiidFont.rounded(15), color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 24.dp).padding(top = 6.dp))
        Text(sourceTitle, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
            modifier = Modifier.padding(horizontal = 24.dp).padding(top = 2.dp))

        Spacer(Modifier.height(24.dp))
        Column(Modifier.padding(horizontal = 24.dp)) {
            restoreStages.forEachIndexed { index, stage ->
                StageRow(stage, state = when {
                    index < stageIndex -> StageState.DONE
                    index == stageIndex && !failed -> StageState.ACTIVE
                    else -> StageState.PENDING
                })
                if (index < restoreStages.size - 1) {
                    Box(Modifier.padding(start = 21.dp).width(1.dp).height(18.dp)
                        .background(VoiidColor.divider.copy(alpha = 0.5f)))
                }
            }
        }

        error?.let {
            Spacer(Modifier.height(14.dp))
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error,
                modifier = Modifier.padding(horizontal = 24.dp))
        }

        Spacer(Modifier.weight(1f))
        if (failed) {
            OnbAccentButton(title = "Try again", enabled = true,
                modifier = Modifier.padding(horizontal = 24.dp)) { onRetry() }
            Text("Skip for now", style = VoiidFont.rounded(15), color = VoiidColor.textSecondary,
                modifier = Modifier.padding(top = 12.dp, bottom = 32.dp)
                    .noRippleClickable { onSkip() })
        } else {
            Text(
                "Decrypted on this device. Voiid's servers never see the contents.",
                style = VoiidFont.rounded(12), color = VoiidColor.textSecondary.copy(alpha = 0.8f),
                modifier = Modifier.padding(horizontal = 24.dp).padding(bottom = 32.dp),
            )
        }
    }
}

private enum class StageState { DONE, ACTIVE, PENDING }

@Composable
private fun StageRow(stage: RestoreStage, state: StageState) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(
            Modifier.size(30.dp).clip(CircleShape).background(
                when (state) {
                    StageState.DONE -> VoiidColor.success.copy(alpha = 0.15f)
                    StageState.ACTIVE -> VoiidColor.primary.copy(alpha = 0.12f)
                    StageState.PENDING -> VoiidColor.fieldFill
                }
            ),
            contentAlignment = Alignment.Center,
        ) {
            if (state == StageState.DONE) {
                Icon(Icons.Default.Check, null, tint = VoiidColor.success, modifier = Modifier.size(15.dp))
            } else {
                Icon(stage.icon, null,
                    tint = if (state == StageState.ACTIVE) VoiidColor.primary else VoiidColor.textSecondary,
                    modifier = Modifier.size(15.dp).alpha(if (state == StageState.PENDING) 0.55f else 1f))
            }
        }
        Text(
            stage.title,
            style = VoiidFont.rounded(15, if (state != StageState.PENDING) FontWeight.SemiBold else FontWeight.Medium),
            color = if (state == StageState.PENDING) VoiidColor.textSecondary else VoiidColor.textPrimary,
        )
    }
}

// MARK: - Formatting

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

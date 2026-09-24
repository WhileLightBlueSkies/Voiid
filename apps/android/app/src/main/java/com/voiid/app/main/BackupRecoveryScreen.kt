package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.foundation.layout.imePadding
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import com.voiid.app.net.BackupManager
import com.voiid.app.net.BackupService
import com.voiid.app.net.DriveAuthRecoverable
import com.voiid.app.net.GoogleDriveBackupService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * Backup & Recovery settings. State-driven (no NavController) — an internal [Screen]
 * state gates the home / setup / view-phrase / change-PIN sub-screens, mirroring how
 * MainScreen/ChatsHomeView gate children with a remembered flag + conditional composable.
 */
private enum class Screen { HOME, SETUP, VIEW_PHRASE, RETIRE_PIN }

@Composable
fun BackupRecoveryScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val manager = remember { BackupManager(context) }
    val scope = rememberCoroutineScope()

    var screen by remember { mutableStateOf(Screen.HOME) }
    var meta by remember { mutableStateOf<BackupService.BackupMeta?>(null) }
    var loadingMeta by remember { mutableStateOf(true) }
    var setUp by remember { mutableStateOf(manager.isSetUp()) }
    // A failed refresh KEEPS the last good metadata and reports why — converting a network
    // failure into "no backup" would tell someone their safety net is gone when the truth
    // is only that we couldn't ask. Mirrors iOS `statusError`.
    var statusError by remember { mutableStateOf<String?>(null) }
    // Outcome feedback: errors surface next to the action; successes flash a toast.
    var actionError by remember { mutableStateOf<String?>(null) }
    var progress by remember { mutableStateOf("Preparing backup…") }
    var backingUp by remember { mutableStateOf(false) }
    var toast by remember { mutableStateOf<String?>(null) }
    val haptics = LocalVoiidHaptics.current

    fun flash(text: String) {
        toast = text
        haptics.success()
    }
    LaunchedEffect(toast) {
        if (toast != null) { kotlinx.coroutines.delay(2500); toast = null }
    }

    // Google Drive (additional, opt-in destination).
    var serverEnabled by remember { mutableStateOf(manager.isServerEnabled()) }
    var driveEnabled by remember { mutableStateOf(manager.isDriveEnabled()) }
    var driveMeta by remember { mutableStateOf<GoogleDriveBackupService.DriveBackupMeta?>(null) }
    var driveBusy by remember { mutableStateOf(false) }
    var driveError by remember { mutableStateOf<String?>(null) }

    suspend fun reloadDrive() {
        driveEnabled = manager.isDriveEnabled()
        driveMeta = if (driveEnabled) runCatching { manager.fetchDriveMeta() }.getOrNull() else null
    }

    suspend fun reloadMeta() {
        loadingMeta = true
        val result = runCatching { manager.fetchMeta() }
            .onSuccess {
                meta = it
                statusError = null
            }
            .onFailure { statusError = it.message ?: "Couldn't reach the backup service." }
        setUp = manager.isSetUp()
        loadingMeta = false
        reloadDrive()
    }

    LaunchedEffect(Unit) { reloadMeta() }
    // An old PIN-protected copy of the key on the server (pre-S04): offer to remove it.
    var legacyPin by remember { mutableStateOf(false) }
    LaunchedEffect(screen) { if (screen == Screen.HOME) legacyPin = manager.hasLegacyPin() }

    // Re-consent flow (GoogleAuthUtil may need a second grant), then finish enabling.
    val recoveryLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) {
        scope.launch {
            driveBusy = true; driveError = null
            try { manager.enableDriveBackup(); reloadDrive() }
            catch (e: Exception) { driveError = e.message ?: "Couldn't enable Google Drive backup." }
            driveBusy = false
        }
    }
    // Google Sign-In result → enable Drive (uploads the same encrypted blob).
    val signInLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) {
        scope.launch {
            driveBusy = true; driveError = null
            try {
                manager.enableDriveBackup()
                reloadDrive()
            } catch (e: DriveAuthRecoverable) {
                recoveryLauncher.launch(e.recoveryIntent)
            } catch (e: Exception) {
                driveError = e.message ?: "Couldn't enable Google Drive backup."
            }
            driveBusy = false
        }
    }

    when (screen) {
        Screen.HOME -> BackupHome(
            serverEnabled = serverEnabled,
            onServerChange = { manager.setServerEnabled(it); serverEnabled = it },
            setUp = setUp,
            loadingMeta = loadingMeta,
            meta = meta,
            statusError = statusError,
            actionError = actionError,
            toast = toast,
            backingUp = backingUp,
            progress = progress,
            driveEnabled = driveEnabled,
            driveMeta = driveMeta,
            driveBusy = driveBusy,
            driveError = driveError,
            onEnableDrive = {
                driveError = null
                signInLauncher.launch(manager.driveSignInClient().signInIntent)
            },
            onDisableDrive = {
                manager.disableDriveBackup()
                driveError = null
                scope.launch { reloadDrive() }
            },
            onBack = onBack,
            onSetup = { screen = Screen.SETUP },
            onBackupNow = {
                if (!backingUp) {
                    backingUp = true; actionError = null
                    scope.launch {
                        // NOT silent: success flashes a confirmation and refreshes; failure
                        // surfaces an actionable error with the error haptic. Mirrors iOS.
                        runCatching { manager.backupNow { progress = it } }
                            .onSuccess {
                                flash("Backed up")
                                scope.launch { reloadMeta() }
                            }
                            .onFailure {
                                actionError = it.message ?: "Couldn't back up. Check your connection and try again."
                                haptics.error()
                            }
                        backingUp = false
                    }
                }
            },
            onViewPhrase = { screen = Screen.VIEW_PHRASE },
            legacyPin = legacyPin,
            onRetirePin = { screen = Screen.RETIRE_PIN },
        )
        Screen.SETUP -> BackupSetupFlow(
            manager = manager,
            onBack = { screen = Screen.HOME },
            onDone = { screen = Screen.HOME; scope.launch { reloadMeta() }; flash("Backup is set up") },
        )
        Screen.VIEW_PHRASE -> ViewPhraseScreen(
            manager = manager,
            onBack = { screen = Screen.HOME },
        )
        Screen.RETIRE_PIN -> RetirePinScreen(
            manager = manager,
            onBack = { screen = Screen.HOME },
            onDone = { screen = Screen.HOME; flash("Old PIN removed") },
        )
    }
}

// MARK: - Home

@Composable
private fun BackupHome(
    serverEnabled: Boolean,
    onServerChange: (Boolean) -> Unit,
    setUp: Boolean,
    loadingMeta: Boolean,
    meta: BackupService.BackupMeta?,
    statusError: String?,
    actionError: String?,
    toast: String?,
    backingUp: Boolean,
    progress: String,
    driveEnabled: Boolean,
    driveMeta: GoogleDriveBackupService.DriveBackupMeta?,
    driveBusy: Boolean,
    driveError: String?,
    onEnableDrive: () -> Unit,
    onDisableDrive: () -> Unit,
    onBack: () -> Unit,
    onSetup: () -> Unit,
    onBackupNow: () -> Unit,
    onViewPhrase: () -> Unit,
    legacyPin: Boolean,
    onRetirePin: () -> Unit,
) {
    val latestBackup = listOfNotNull(meta, driveMeta?.let {
        BackupService.BackupMeta(size_bytes = it.sizeBytes, updated_at = it.modifiedTime)
    }).maxByOrNull { runCatching { java.time.Instant.parse(it.updated_at).toEpochMilli() }.getOrDefault(0) }
    BackupScaffold(title = "Backup & Recovery", onBack = onBack) {
        // Outcome toast — auto-dismisses; sits at the top where it reads as a receipt.
        if (toast != null) {
            Text(
                toast,
                style = VoiidFont.rounded(13, FontWeight.SemiBold),
                color = VoiidColor.success,
                modifier = Modifier.fillMaxWidth()
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(VoiidColor.success.copy(alpha = 0.10f))
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )
            Spacer(Modifier.height(12.dp))
        }
        Spacer(Modifier.height(4.dp))
        Text(
            "Your messages are end-to-end encrypted. A backup lets you restore them on a " +
                "new device using your PIN or 24-word recovery phrase. Only you can unlock it.",
            style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
        )
        Spacer(Modifier.height(24.dp))

        // Status card.
        Column(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(VoiidRadius.lg))
                .background(VoiidColor.surfaceCard)
                .padding(16.dp),
        ) {
            when {
                loadingMeta -> Text("Checking backup…", style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
                !serverEnabled && !driveEnabled -> {
                    Text("Backup off", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    Text("Choose a location below to turn backup on.", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                }
                setUp && latestBackup != null -> {
                    Text("Backup on", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.success)
                    Spacer(Modifier.height(4.dp))
                    Text("Last backup: ${formatUpdatedAt(latestBackup.updated_at)} · ${formatSize(latestBackup.size_bytes)}",
                        style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                }
                setUp -> {
                    Text("Backup on", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.success)
                    Spacer(Modifier.height(4.dp))
                    Text("No backup uploaded yet.", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                }
                else -> {
                    Text("Not set up", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                    Spacer(Modifier.height(4.dp))
                    Text("Set up a backup so you never lose your chats.",
                        style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
                }
            }
            // The refresh itself failing is its own state — shown WITHOUT erasing the last
            // good metadata above.
            statusError?.let {
                Spacer(Modifier.height(6.dp))
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            }
        }

        Spacer(Modifier.height(24.dp))

        Text("Backup locations", style = VoiidFont.rounded(17, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Text("Choose Voiid server, Google Drive, both, or neither. Turning a location off keeps existing backups.",
            style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Voiid server", Modifier.weight(1f), color = VoiidColor.textPrimary)
            androidx.compose.material3.Switch(checked = serverEnabled, onCheckedChange = onServerChange, enabled = !backingUp)
        }
        DriveBackupSection(driveEnabled, driveMeta, driveBusy || backingUp, driveError, onEnableDrive, onDisableDrive)
        Spacer(Modifier.height(24.dp))
        if (!setUp) {
            BackupButton("Set up backup", enabled = serverEnabled || driveEnabled, onClick = onSetup)
        } else {
            BackupButton(if (backingUp) progress else "Back up now", enabled = !backingUp && (serverEnabled || driveEnabled), onClick = onBackupNow)
            actionError?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            }
            Spacer(Modifier.height(12.dp))
            BackupSecondaryButton("View recovery phrase", onClick = onViewPhrase)
            if (legacyPin) {
                Spacer(Modifier.height(16.dp))
                Text(
                    "Your backup can still be opened with an old PIN. A short PIN can be guessed; " +
                        "your 24-word recovery phrase can't. Save your phrase, then remove the PIN.",
                    style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                )
                Spacer(Modifier.height(10.dp))
                BackupSecondaryButton("Remove old backup PIN", onClick = onRetirePin)
            }


        }
    }
}

// MARK: - Google Drive destination (additional to the server backup)

@Composable
private fun DriveBackupSection(
    enabled: Boolean,
    meta: GoogleDriveBackupService.DriveBackupMeta?,
    busy: Boolean,
    error: String?,
    onEnable: () -> Unit,
    onDisable: () -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        Text("Google Drive backup",
            style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Spacer(Modifier.height(6.dp))
        Text(
            "Keep the same end-to-end encrypted backup in your own private Google Drive folder " +
                "as your backup location. Google only ever sees ciphertext — never your messages or key.",
            style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
        )
        Spacer(Modifier.height(12.dp))
        if (enabled) {
            Text("Drive backup on",
                style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.success)
            Spacer(Modifier.height(4.dp))
            Text("Last Drive backup: ${formatUpdatedAt(meta?.modifiedTime)}",
                style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
            Spacer(Modifier.height(12.dp))
            BackupSecondaryButton(if (busy) "Working…" else "Turn off Drive backup") { if (!busy) onDisable() }
        } else {
            BackupSecondaryButton(if (busy) "Connecting…" else "Back up to Google Drive") { if (!busy) onEnable() }
            Spacer(Modifier.height(8.dp))
            Text("Requires Google sign-in setup.",
                style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
        }
        error?.let {
            Spacer(Modifier.height(10.dp))
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
        }
    }
}

// MARK: - Setup flow

/**
 * Setting up backup: the 24-word phrase, proof it was written down, then the first backup.
 *
 * THE PHRASE IS THE ONLY WAY BACK IN (S04). There used to be a PIN whose wrapped key sat on the
 * server — an 8-digit PIN can be tried offline by anyone who obtains that copy. It is gone, which
 * makes the phrase load-bearing, so setup asks for three of its words back.
 */
private enum class SetupStep { PHRASE, VERIFY }

@Composable
private fun BackupSetupFlow(manager: BackupManager, onBack: () -> Unit, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var step by remember { mutableStateOf(SetupStep.PHRASE) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var written by remember { mutableStateOf(false) }
    val made = remember { runCatching { manager.newSecretAndPhrase() }.getOrNull() }
    val secret = made?.first
    val phrase = made?.second.orEmpty()

    if (made == null) {
        BackupScaffold(title = "Set up backup", onBack = onBack) {
            Text("Couldn't generate a recovery phrase. Go back and try again.",
                style = VoiidFont.rounded(15), color = VoiidColor.error)
        }
        return
    }

    when (step) {
        SetupStep.PHRASE -> RecoveryPhraseScreen(
            phrase = phrase,
            confirmed = written,
            onToggleConfirmed = { written = !written },
            error = null,
            busy = false,
            cta = "Next",
            ctaEnabled = written,
            onBack = onBack,
            onSubmit = { step = SetupStep.VERIFY; error = null },
        )
        SetupStep.VERIFY -> PhraseVerifyScreen(
            phrase = phrase,
            busy = busy,
            error = error,
            cta = if (busy) "Setting up…" else "Finish setup",
            onBack = { step = SetupStep.PHRASE; error = null },
            onVerified = {
                val s = secret ?: return@PhraseVerifyScreen
                busy = true; error = null
                scope.launch {
                    try {
                        manager.finalizeSetup(s)
                        onDone()
                    } catch (e: Exception) {
                        error = e.message ?: "Backup setup failed. Try again."
                    }
                    busy = false
                }
            },
        )
    }
}

/**
 * Three words of the phrase, typed back — one from each third, so the check cannot be passed by
 * remembering the first line. Forgiving about case and spaces, strict about the word.
 */
@Composable
private fun PhraseVerifyScreen(
    phrase: String,
    busy: Boolean,
    error: String?,
    cta: String,
    onBack: () -> Unit,
    onVerified: () -> Unit,
) {
    val words = remember(phrase) { phrase.trim().split(Regex("\\s+")) }
    val positions = remember(phrase) {
        val third = maxOf(1, words.size / 3)
        (0 until 3).map { i -> (i * third until minOf(words.size, (i + 1) * third)).random() }
    }
    val answers = remember(phrase) { androidx.compose.runtime.mutableStateListOf("", "", "") }
    var wrong by remember { mutableStateOf(setOf<Int>()) }
    val haptics = LocalVoiidHaptics.current

    BackupScaffold(title = "Check your phrase", onBack = onBack) {
        Spacer(Modifier.height(8.dp))
        Text("Type these words from your phrase", style = VoiidFont.rounded(20, FontWeight.SemiBold),
            color = VoiidColor.textPrimary)
        Spacer(Modifier.height(6.dp))
        Text("This is the only way to restore your chats on a new phone, so it's worth one check.",
            style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
        Spacer(Modifier.height(20.dp))
        positions.forEachIndexed { i, position ->
            Text("Word ${position + 1}", style = VoiidFont.rounded(13, FontWeight.SemiBold),
                color = VoiidColor.textSecondary)
            Spacer(Modifier.height(6.dp))
            val shape = RoundedCornerShape(12.dp)
            BasicTextField(
                value = answers[i],
                onValueChange = { answers[i] = it; wrong = wrong - i },
                singleLine = true,
                textStyle = VoiidFont.rounded(17).merge(TextStyle(color = VoiidColor.textPrimary)),
                cursorBrush = SolidColor(VoiidColor.primary),
                modifier = Modifier.fillMaxWidth().height(48.dp).clip(shape)
                    .background(VoiidColor.fieldFill)
                    .border(1.dp, if (i in wrong) VoiidColor.error else VoiidColor.fieldBorder, shape)
                    .padding(horizontal = 14.dp, vertical = 13.dp),
            )
            if (i in wrong) {
                Spacer(Modifier.height(4.dp))
                Text("That's not word ${position + 1}.", style = VoiidFont.rounded(12), color = VoiidColor.error)
            }
            Spacer(Modifier.height(14.dp))
        }
        error?.let {
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            Spacer(Modifier.height(10.dp))
        }
        BackupButton(cta, enabled = !busy && answers.all { it.isNotBlank() }) {
            wrong = positions.indices.filter { i ->
                answers[i].trim().lowercase() != words[positions[i]].lowercase()
            }.toSet()
            if (wrong.isEmpty()) { haptics.success(); onVerified() } else haptics.error()
        }
    }
}

// MARK: - View recovery phrase

@Composable
private fun ViewPhraseScreen(manager: BackupManager, onBack: () -> Unit) {
    val phrase = remember { runCatching { manager.recoveryPhrase() }.getOrNull() }
    BackupScaffold(title = "Recovery phrase", onBack = onBack) {
        if (phrase == null) {
            Text("No recovery phrase on this device.", style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
            return@BackupScaffold
        }
        Spacer(Modifier.height(8.dp))
        Text(
            "Write these 24 words down and keep them somewhere safe. This is the ONLY way to " +
                "restore your chats on a new phone. Never share them.",
            style = VoiidFont.rounded(14), color = VoiidColor.error,
        )
        Spacer(Modifier.height(20.dp))
        PhraseGrid(phrase)
    }
}

// MARK: - Remove the old PIN

/**
 * For an account whose key still has an old PIN-protected copy on the server: the phrase, a
 * check of it, then delete that copy. After this only the phrase restores the backup — which is
 * the point, and why the phrase is checked first.
 */
@Composable
private fun RetirePinScreen(manager: BackupManager, onBack: () -> Unit, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    val phrase = remember { runCatching { manager.recoveryPhrase() }.getOrNull() }
    var verifying by remember { mutableStateOf(false) }
    var written by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    if (phrase == null) {
        BackupScaffold(title = "Remove old PIN", onBack = onBack) {
            Text("Backup isn't set up on this device.", style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
        }
        return
    }
    if (!verifying) {
        RecoveryPhraseScreen(
            phrase = phrase,
            confirmed = written,
            onToggleConfirmed = { written = !written },
            error = null,
            busy = false,
            cta = "Next",
            ctaEnabled = written,
            onBack = onBack,
            onSubmit = { verifying = true },
        )
    } else {
        PhraseVerifyScreen(
            phrase = phrase,
            busy = busy,
            error = error,
            cta = if (busy) "Removing…" else "Remove old PIN",
            onBack = { verifying = false; error = null },
            onVerified = {
                busy = true; error = null
                scope.launch {
                    try {
                        manager.retireLegacyPin()
                        onDone()
                    } catch (e: Exception) {
                        error = e.message ?: "Couldn't remove the old PIN. Try again."
                    }
                    busy = false
                }
            },
        )
    }
}

// MARK: - Shared building blocks (internal — reused by the login-restore flow)

/**
 * The backup PIN is EXACTLY EIGHT digits — setup, confirm, change, and restore all enforce it.
 *
 * The wrap is only as strong as the PIN is unguessable offline: at roughly 300ms per Argon2id
 * guess per core, six digits is expensive but finite, and eight is 100 million candidates —
 * years on commodity hardware, which is where the recovery phrase rather than the PIN becomes
 * the weakest way in. Matches iOS `PinRules`.
 */
internal const val VOIID_PIN_LENGTH = 8

/** Simple full-screen scaffold with a circular back button + title, matching onboarding. */
@Composable
internal fun BackupScaffold(
    title: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    actions: (@Composable () -> Unit)? = null,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    Column(
        modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding().navigationBarsPadding(),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).height(56.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Bare chevron on the background, matching iOS's navigation back item. The
            // white disc this was is a floating control, and hardcoded white made it a
            // bright circle on a dark screen in dark mode.
            Box(
                Modifier.size(38.dp).clip(CircleShape)
                    .softClickable(scale = 0.9f) { haptics.tap(); onBack() },
                contentAlignment = Alignment.CenterStart,
            ) {
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, "Back",
                    tint = VoiidColor.textPrimary, modifier = Modifier.size(30.dp))
            }
            // CENTRED and inline-sized: iOS's settings screens all use
            // .navigationBarTitleDisplayMode(.inline), which is a 17pt semibold title in
            // the middle of the bar — not a large bold heading pushed against the chevron.
            Text(
                title,
                style = VoiidFont.rounded(17, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
                textAlign = TextAlign.Center,
                modifier = Modifier.weight(1f),
            )
            // Balances the chevron so the title is centred on the SCREEN, not on the
            // space left over beside it.
            if (actions != null) actions() else Spacer(Modifier.width(38.dp))
        }
        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp).padding(bottom = 24.dp),
            content = content,
        )
    }
}

/** Accent pill primary button. */
@Composable
internal fun BackupButton(title: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.fillMaxWidth().height(56.dp)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(if (enabled) VoiidColor.accent else VoiidColor.accent.copy(alpha = 0.5f))
            .softClickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = VoiidFont.rounded(17, FontWeight.Medium), color = VoiidColor.textPrimary)
    }
}

/** Outlined pill secondary button. */
@Composable
internal fun BackupSecondaryButton(title: String, onClick: () -> Unit) {
    Box(
        Modifier.fillMaxWidth().height(56.dp)
            .clip(RoundedCornerShape(VoiidRadius.pill))
            .background(VoiidColor.fieldFill)
            .border(1.dp, VoiidColor.fieldBorder, RoundedCornerShape(VoiidRadius.pill))
            .softClickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = VoiidFont.rounded(17, FontWeight.Medium), color = VoiidColor.textPrimary)
    }
}

/** Numeric PIN entry screen (masked). Reused by setup + change-PIN + restore. */
@Composable
internal fun PinEntryScreen(
    title: String,
    subtitle: String,
    value: String,
    onValueChange: (String) -> Unit,
    error: String?,
    busy: Boolean,
    cta: String,
    ctaEnabled: Boolean,
    onBack: () -> Unit,
    onSubmit: () -> Unit,
    footer: (@Composable () -> Unit)? = null,
) {
    BackupScaffold(title = title, onBack = onBack, modifier = Modifier.imePadding()) {
        Spacer(Modifier.height(8.dp))
        Text(subtitle, style = VoiidFont.rounded(14), color = VoiidColor.textSecondary)
        Spacer(Modifier.height(28.dp))
        PinField(value = value, onValueChange = { onValueChange(it.filter(Char::isDigit).take(VOIID_PIN_LENGTH)) })
        error?.let {
            Spacer(Modifier.height(10.dp))
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
        }
        Spacer(Modifier.height(28.dp))
        BackupButton(if (busy) "$cta" else cta, enabled = ctaEnabled, onClick = onSubmit)
        footer?.let { Spacer(Modifier.height(16.dp)); it() }
    }
}

@Composable
internal fun PinField(value: String, onValueChange: (String) -> Unit, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(16.dp)
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    var focused by remember { mutableStateOf(false) }
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text("8-digit PIN", style = VoiidFont.rounded(14, FontWeight.Medium), color = VoiidColor.textSecondary)
        Text("${value.length} / $VOIID_PIN_LENGTH", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
    }
    BasicTextField(
        value = value,
        onValueChange = { onValueChange(it.filter { digit -> digit in '0'..'9' }.take(VOIID_PIN_LENGTH)) },
        singleLine = true,
        textStyle = VoiidFont.rounded(24, FontWeight.SemiBold).merge(TextStyle(color = VoiidColor.textPrimary, textAlign = TextAlign.Center)),
        cursorBrush = SolidColor(VoiidColor.primary),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = androidx.compose.ui.text.input.ImeAction.Done),
        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { focus.clearFocus() }),
        visualTransformation = PasswordVisualTransformation(),
        modifier = Modifier.fillMaxWidth().height(64.dp).onFocusChanged { focused = it.isFocused }.clip(shape)
            .background(VoiidColor.fieldFill).border(if (focused) 1.5.dp else 1.dp, if (focused) VoiidColor.accent else VoiidColor.fieldBorder, shape),
        decorationBox = { inner ->
            Box(Modifier.fillMaxWidth().padding(horizontal = 20.dp), contentAlignment = Alignment.Center) {
                if (value.isEmpty()) {
                    Text("Enter 8 digits", style = VoiidFont.rounded(18), color = VoiidColor.placeholder)
                }
                inner()
            }
        },
    )
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        repeat(VOIID_PIN_LENGTH) { index ->
            Box(Modifier.weight(1f).height(3.dp).background(
                if (index < value.length) VoiidColor.accent else VoiidColor.fieldBorder, RoundedCornerShape(2.dp)))
        }
    }

    }
}

/** Recovery-phrase display + "I've written it down" confirmation (setup step). */
@Composable
private fun RecoveryPhraseScreen(
    phrase: String,
    confirmed: Boolean,
    onToggleConfirmed: () -> Unit,
    error: String?,
    busy: Boolean,
    cta: String,
    ctaEnabled: Boolean,
    onBack: () -> Unit,
    onSubmit: () -> Unit,
) {
    BackupScaffold(title = "Recovery phrase", onBack = onBack) {
        Spacer(Modifier.height(8.dp))
        Text(
            "Write down these 24 words in order and keep them safe. If you forget your PIN, " +
                "this phrase is the ONLY way to restore your chats. Never share it.",
            style = VoiidFont.rounded(14), color = VoiidColor.error,
        )
        Spacer(Modifier.height(20.dp))
        PhraseGrid(phrase)
        Spacer(Modifier.height(24.dp))
        Row(
            Modifier.fillMaxWidth().softClickable(onClick = onToggleConfirmed),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            val boxShape = RoundedCornerShape(4.dp)
            Box(
                Modifier.size(20.dp).clip(boxShape)
                    .background(if (confirmed) VoiidColor.primary else Color.Transparent)
                    .border(1.dp, VoiidColor.textSecondary, boxShape),
                contentAlignment = Alignment.Center,
            ) {
                if (confirmed) Icon(Icons.Default.Check, null, tint = Color.White, modifier = Modifier.size(13.dp))
            }
            Text("I've written down my recovery phrase", style = VoiidFont.rounded(14), color = VoiidColor.textPrimary)
        }
        error?.let {
            Spacer(Modifier.height(10.dp))
            Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
        }
        Spacer(Modifier.height(24.dp))
        BackupButton(cta, enabled = ctaEnabled, onClick = onSubmit)
    }
}

/** 24-word numbered grid, two words per row. */
@Composable
internal fun PhraseGrid(phrase: String) {
    val words = phrase.trim().split(Regex("\\s+"))
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        words.chunked(2).forEachIndexed { rowIdx, pair ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                pair.forEachIndexed { colIdx, word ->
                    val n = rowIdx * 2 + colIdx + 1
                    Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                        Text("$n.", style = VoiidFont.rounded(13), color = VoiidColor.textSecondary,
                            modifier = Modifier.width(24.dp))
                        Text(word, style = VoiidFont.rounded(15, FontWeight.Medium), color = VoiidColor.textPrimary)
                    }
                }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** Small loading spinner (shared). */
@Composable
internal fun BackupSpinner() {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = VoiidColor.primary, modifier = Modifier.size(28.dp))
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
    // Server sends ISO-8601; show the date+time portion without the timezone noise.
    return raw.replace('T', ' ').substringBefore('.').substringBefore('+').trim().ifBlank { raw }
}

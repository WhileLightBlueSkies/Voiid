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
private enum class Screen { HOME, SETUP, VIEW_PHRASE, CHANGE_PIN }

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
    var driveEnabled by remember { mutableStateOf(manager.isDriveEnabled() && manager.isDriveSignedIn()) }
    var driveMeta by remember { mutableStateOf<GoogleDriveBackupService.DriveBackupMeta?>(null) }
    var driveBusy by remember { mutableStateOf(false) }
    var driveError by remember { mutableStateOf<String?>(null) }

    suspend fun reloadDrive() {
        driveEnabled = manager.isDriveEnabled() && manager.isDriveSignedIn()
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
        if (result.isSuccess) reloadDrive()
    }

    LaunchedEffect(Unit) { reloadMeta() }

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
            setUp = setUp,
            loadingMeta = loadingMeta,
            meta = meta,
            statusError = statusError,
            actionError = actionError,
            toast = toast,
            backingUp = backingUp,
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
                        runCatching { manager.backupNow() }
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
            onChangePin = { screen = Screen.CHANGE_PIN },
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
        Screen.CHANGE_PIN -> ChangePinScreen(
            manager = manager,
            onBack = { screen = Screen.HOME },
            onDone = { screen = Screen.HOME; flash("PIN changed") },
        )
    }
}

// MARK: - Home

@Composable
private fun BackupHome(
    setUp: Boolean,
    loadingMeta: Boolean,
    meta: BackupService.BackupMeta?,
    statusError: String?,
    actionError: String?,
    toast: String?,
    backingUp: Boolean,
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
    onChangePin: () -> Unit,
) {
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
                setUp && meta != null -> {
                    Text("Backup on", style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.success)
                    Spacer(Modifier.height(4.dp))
                    Text("Last backup: ${formatUpdatedAt(meta.updated_at)} · ${formatSize(meta.size_bytes)}",
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

        if (!setUp) {
            BackupButton("Set up backup", enabled = true, onClick = onSetup)
        } else {
            BackupButton(if (backingUp) "Backing up…" else "Back up now", enabled = !backingUp, onClick = onBackupNow)
            actionError?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.error)
            }
            Spacer(Modifier.height(12.dp))
            BackupSecondaryButton("View recovery phrase", onClick = onViewPhrase)
            Spacer(Modifier.height(12.dp))
            BackupSecondaryButton("Change PIN", onClick = onChangePin)

            Spacer(Modifier.height(28.dp))
            DriveBackupSection(
                enabled = driveEnabled,
                meta = driveMeta,
                busy = driveBusy,
                error = driveError,
                onEnable = onEnableDrive,
                onDisable = onDisableDrive,
            )
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
                "as an extra copy. Google only ever sees ciphertext — never your messages or key.",
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

private enum class SetupStep { PIN, CONFIRM, PHRASE }

@Composable
private fun BackupSetupFlow(manager: BackupManager, onBack: () -> Unit, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var step by remember { mutableStateOf(SetupStep.PIN) }
    var pin by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var written by remember { mutableStateOf(false) }
    // Generated once we reach the phrase step; held only in memory until finalize.
    var secret by remember { mutableStateOf<ByteArray?>(null) }
    var phrase by remember { mutableStateOf("") }

    when (step) {
        SetupStep.PIN -> PinEntryScreen(
            title = "Choose a PIN",
            subtitle = "Pick a 6-digit PIN. You'll need it to restore your chats on a new device.",
            value = pin, onValueChange = { pin = it; error = null },
            error = error, busy = false, cta = "Next",
            ctaEnabled = pin.length == VOIID_PIN_LENGTH,
            onBack = onBack,
            onSubmit = { step = SetupStep.CONFIRM; error = null },
        )
        SetupStep.CONFIRM -> PinEntryScreen(
            title = "Confirm your PIN",
            subtitle = "Enter the same PIN again.",
            value = confirm, onValueChange = { confirm = it; error = null },
            error = error, busy = busy, cta = "Continue",
            ctaEnabled = confirm.length == VOIID_PIN_LENGTH && !busy,
            onBack = { step = SetupStep.PIN; confirm = ""; error = null },
            onSubmit = {
                if (confirm != pin) { error = "PINs don't match."; confirm = ""; return@PinEntryScreen }
                busy = true; error = null
                scope.launch {
                    try {
                        val (s, p) = manager.newSecretAndPhrase()
                        secret = s; phrase = p
                        step = SetupStep.PHRASE
                    } catch (e: Exception) {
                        error = e.message ?: "Couldn't generate recovery phrase."
                    }
                    busy = false
                }
            },
        )
        SetupStep.PHRASE -> RecoveryPhraseScreen(
            phrase = phrase,
            confirmed = written,
            onToggleConfirmed = { written = !written },
            error = error,
            busy = busy,
            cta = if (busy) "Setting up…" else "Finish setup",
            ctaEnabled = written && !busy,
            onBack = { step = SetupStep.CONFIRM; error = null },
            onSubmit = {
                val s = secret ?: return@RecoveryPhraseScreen
                busy = true; error = null
                scope.launch {
                    try {
                        manager.finalizeSetup(s, pin)
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
                "restore your chats if you forget your PIN. Never share them.",
            style = VoiidFont.rounded(14), color = VoiidColor.error,
        )
        Spacer(Modifier.height(20.dp))
        PhraseGrid(phrase)
    }
}

// MARK: - Change PIN

@Composable
private fun ChangePinScreen(manager: BackupManager, onBack: () -> Unit, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var newPin by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var confirming by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    if (!confirming) {
        PinEntryScreen(
            title = "New PIN",
            subtitle = "Choose a new 6-digit PIN.",
            value = newPin, onValueChange = { newPin = it; error = null },
            error = error, busy = false, cta = "Next",
            ctaEnabled = newPin.length == VOIID_PIN_LENGTH,
            onBack = onBack,
            onSubmit = { confirming = true; error = null },
        )
    } else {
        PinEntryScreen(
            title = "Confirm new PIN",
            subtitle = "Enter the new PIN again.",
            value = confirm, onValueChange = { confirm = it; error = null },
            error = error, busy = busy, cta = if (busy) "Saving…" else "Save",
            ctaEnabled = confirm.length == VOIID_PIN_LENGTH && !busy,
            onBack = { confirming = false; confirm = ""; error = null },
            onSubmit = {
                if (confirm != newPin) { error = "PINs don't match."; confirm = ""; return@PinEntryScreen }
                busy = true; error = null
                scope.launch {
                    try {
                        manager.changePin(newPin)
                        onDone()
                    } catch (e: Exception) {
                        error = e.message ?: "Couldn't change PIN."
                    }
                    busy = false
                }
            },
        )
    }
}

// MARK: - Shared building blocks (internal — reused by the login-restore flow)

/** The backup PIN is EXACTLY SIX digits — setup, confirm, change, and restore all enforce it. */
internal const val VOIID_PIN_LENGTH = 6

/** Simple full-screen scaffold with a circular back button + title, matching onboarding. */
@Composable
internal fun BackupScaffold(
    title: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
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
            Box(
                Modifier.size(38.dp).clip(CircleShape).background(Color.White)
                    .softClickable(scale = 0.9f) { haptics.tap(); onBack() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, "Back",
                    tint = VoiidColor.textPrimary, modifier = Modifier.size(26.dp))
            }
            Spacer(Modifier.width(12.dp))
            Text(title, style = VoiidFont.rounded(20, FontWeight.Bold), color = VoiidColor.textPrimary)
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
    BackupScaffold(title = title, onBack = onBack) {
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
private fun PinField(value: String, onValueChange: (String) -> Unit) {
    val shape = RoundedCornerShape(VoiidRadius.pill)
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        textStyle = VoiidFont.rounded(20, FontWeight.SemiBold).merge(TextStyle(color = VoiidColor.textPrimary, textAlign = TextAlign.Center)),
        cursorBrush = SolidColor(VoiidColor.primary),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
        visualTransformation = PasswordVisualTransformation(),
        modifier = Modifier.fillMaxWidth().height(56.dp).clip(shape)
            .background(VoiidColor.fieldFill).border(1.dp, VoiidColor.fieldBorder, shape),
        decorationBox = { inner ->
            Box(Modifier.fillMaxWidth().padding(horizontal = 20.dp), contentAlignment = Alignment.Center) {
                if (value.isEmpty()) {
                    Text("PIN", style = VoiidFont.rounded(18), color = VoiidColor.placeholder)
                }
                inner()
            }
        },
    )
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

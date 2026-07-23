package com.voiid.app.main

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.net.BackupManager
import com.voiid.app.net.StorageProbe
import com.voiid.app.net.StorageSnapshot
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch
import java.text.NumberFormat
import kotlin.math.ln
import kotlin.math.pow

/**
 * Settings -> Storage. Port of iOS `StorageSettingsView.swift` / `StorageProbe.swift`.
 *
 * Every number here is measured by [StorageProbe], never asserted. Two rules carried over:
 *  1. Never render "0 B" before the first measurement — rows show "…" until [snapshot]
 *     lands, a placeholder rather than a number the user could read as fact.
 *  2. Offer only what can actually be reclaimed. "Clear Caches" clears exactly Coil's
 *     image disk cache + orphaned voice-note scratch files, and disables when both are
 *     zero. See [StorageProbe]'s doc for the full account of what is deliberately absent
 *     (message history, database rows, keychain) and why.
 */
@Composable
fun StorageSettingsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val manager = remember { BackupManager(context) }

    var snapshot by remember { mutableStateOf<StorageSnapshot?>(null) }
    var isClearing by remember { mutableStateOf(false) }
    var backupState by remember { mutableStateOf<BackupRowState>(BackupRowState.Loading) }

    suspend fun measure() { snapshot = StorageProbe.measure(context) }

    suspend fun loadBackup() {
        if (!manager.isSetUp()) { backupState = BackupRowState.NotSetUp; return }
        backupState = try {
            val meta = manager.fetchMeta()
            if (meta != null) BackupRowState.Present(meta.size_bytes, meta.updated_at) else BackupRowState.NotSetUp
        } catch (e: Exception) {
            BackupRowState.CouldNotCheck
        }
    }

    LaunchedEffect(Unit) { measure(); loadBackup() }

    BackupScaffold(title = "Storage", onBack = onBack) {
        Spacer(Modifier.height(8.dp))

        StorageSection(
            header = "On this device",
            footer = "Your messages are stored on this device so chats open instantly and " +
                "work offline. Photos, videos and voice notes are never written to this " +
                "device — they're downloaded and decrypted only while you're looking at them.",
        ) {
            MetricRow("Total", snapshot?.let { formatBytes(it.containerTotalBytes) }, emphasised = true)
            MetricRow("Database", snapshot?.let { formatBytes(it.databaseBytes) })
            MetricRow("Message history", snapshot?.let { formatBytes(it.messageHistoryBytes) })
            MetricRow("Other", snapshot?.let { formatBytes(it.otherBytes) })
        }

        Spacer(Modifier.height(20.dp))

        StorageSection(
            header = "Contents",
            footer = "Counted from this device's database. These numbers stay on your phone and aren't reported anywhere.",
        ) {
            MetricRow("Conversations", snapshot?.conversationCount?.let { formatCount(it) })
            MetricRow("Messages", snapshot?.messageCount?.let { formatCount(it) })
            MetricRow("Calls logged", snapshot?.callCount?.let { formatCount(it) })
        }

        Spacer(Modifier.height(20.dp))

        StorageSection(
            header = "Caches",
            footer = "Clearing removes only files Voiid can create or download again. Your messages, media and backups aren't affected.",
        ) {
            MetricRow("Image cache", snapshot?.let { formatBytes(it.imageCacheBytes) })
            MetricRow("Temporary files", snapshot?.let { formatBytes(it.temporaryFileBytes) })
            val clearable = snapshot?.clearableBytes ?: 0
            Row(
                Modifier.fillMaxWidth()
                    .softClickable(enabled = !isClearing && clearable > 0) {
                        scope.launch {
                            isClearing = true
                            StorageProbe.clearCaches(context)
                            measure()
                            isClearing = false
                        }
                    }
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    "Clear Caches", style = VoiidFont.rounded(15),
                    color = if (!isClearing && clearable > 0) VoiidColor.primary else VoiidColor.textSecondary,
                )
                if (isClearing) CircularProgressIndicator(modifier = Modifier.height(16.dp), color = VoiidColor.primary)
            }
        }

        Spacer(Modifier.height(20.dp))

        StorageSection(
            header = "Backup",
            footer = "Backups are stored encrypted off this device, so they don't count towards the storage above.",
        ) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Cloud backup", style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
                Text(backupValueText(backupState), style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
            }
        }
    }
}

private sealed class BackupRowState {
    object Loading : BackupRowState()
    object NotSetUp : BackupRowState()
    object CouldNotCheck : BackupRowState()
    data class Present(val bytes: Long, val updatedAt: String?) : BackupRowState()
}

private fun backupValueText(state: BackupRowState): String = when (state) {
    is BackupRowState.Loading -> "Checking…"
    is BackupRowState.NotSetUp -> "Not set up"
    is BackupRowState.CouldNotCheck -> "Couldn't check"
    is BackupRowState.Present -> formatBytes(state.bytes)
}

@Composable
private fun StorageSection(header: String, footer: String, content: @Composable () -> Unit) {
    Text(header, style = VoiidFont.rounded(13, FontWeight.SemiBold), color = VoiidColor.textSecondary)
    Spacer(Modifier.height(8.dp))
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.lg)).background(VoiidColor.surfaceCard),
        content = { content() },
    )
    Spacer(Modifier.height(8.dp))
    Text(footer, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
}

/** `value == null` means not yet measured — shows "…" rather than a fabricated zero. */
@Composable
private fun MetricRow(title: String, value: String?, emphasised: Boolean = false) {
    Row(
        Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            title, style = VoiidFont.rounded(15, if (emphasised) FontWeight.SemiBold else FontWeight.Normal),
            color = VoiidColor.textPrimary, modifier = Modifier.weight(1f),
        )
        Text(
            value ?: "…",
            style = VoiidFont.rounded(13, if (emphasised) FontWeight.SemiBold else FontWeight.Normal),
            color = if (emphasised) VoiidColor.textPrimary else VoiidColor.textSecondary,
        )
    }
}

private fun formatCount(n: Int): String = NumberFormat.getIntegerInstance().format(n)

/** Matches iOS's `.byteCount(style: .file)` closely enough: base-1000 units, one decimal. */
private fun formatBytes(bytes: Long): String {
    if (bytes < 1000) return "$bytes B"
    val units = arrayOf("KB", "MB", "GB", "TB")
    val exp = (ln(bytes.toDouble()) / ln(1000.0)).toInt().coerceIn(1, units.size)
    val value = bytes / 1000.0.pow(exp)
    return String.format("%.1f %s", value, units[exp - 1])
}

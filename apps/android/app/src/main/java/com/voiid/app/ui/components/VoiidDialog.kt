package com.voiid.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * The Voiid alert — the one branded modal-dialog primitive behind every audited confirmation,
 * refusal and notice. Replaces Material `AlertDialog`, whose default surface/scrim/button
 * treatment broke parity with the iOS alert language.
 *
 * Contract (component backlog):
 *  - Branded surface/radius/stroke/scrim (tokens below, centralised for calibration).
 *  - Title/body/action hierarchy: ONE destructive confirm, ONE neutral cancel — a destructive
 *    action is never parked in a dismiss-button slot merely to fit a two-button API ([cancel]
 *    is always the neutral escape).
 *  - Disabled and busy states ([enabled], [busy] — busy swaps the confirm label for progress
 *    and swallows taps).
 *  - Back/scrim dismissal policy ([backDismissable], [scrimDismissable]).
 *  - Keyboard avoidance built in ([imePadding] + scrollable body).
 *  - Error/success haptic hooks: fire [hapticOnConfirm] from the caller's own handler — this
 *    primitive plays NO haptics itself except the rigid press on a DESTRUCTIVE confirm, so a
 *    caller cannot end up with two.
 *
 * Two shapes cover every audited site: the simple string API below, and [VoiidDialogCustom]
 * for bodies that need composables (role menus, text fields).
 */
object VoiidDialogTokens {
    var topRadius: Dp = 20.dp
    const val SCRIM_ALPHA: Float = 0.45f
}

/** A DESTRUCTIVE confirm gets the heavier press haptic exactly once, here. */
@Composable
fun VoiidDialog(
    onDismissRequest: () -> Unit,
    title: String,
    body: String? = null,
    modifier: Modifier = Modifier,
    confirmLabel: String? = null,
    onConfirm: (() -> Unit)? = null,
    confirmEnabled: Boolean = true,
    /** Destructive confirms render in the error colour and carry the rigid press haptic. */
    confirmDestructive: Boolean = false,
    /** Neutral escape hatch. Never carries the destructive action. */
    cancelLabel: String? = "Cancel",
    onCancel: (() -> Unit)? = null,
    /** Busy state: confirm shows progress and both buttons swallow taps. */
    busy: Boolean = false,
    backDismissable: Boolean = true,
    scrimDismissable: Boolean = true,
    /** Optional extra row rendered between body and actions (e.g. an inline error line). */
    footer: (@Composable ColumnScope.() -> Unit)? = null,
) {
    val haptics = LocalVoiidHaptics.current

    fun requestClose() {
        if (!busy) onDismissRequest()
    }

    Dialog(
        onDismissRequest = { if (backDismissable) requestClose() },
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
            dismissOnBackPress = false, // routed through the animated handler above
            dismissOnClickOutside = false,
        ),
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(scrimDismissable, busy) {
                    detectTapGestures { if (scrimDismissable && !busy) onDismissRequest() }
                },
            contentAlignment = Alignment.Center,
        ) {
            Column(
                Modifier
                    .padding(horizontal = 32.dp)
                    .widthIn(max = 360.dp)
                    .clip(RoundedCornerShape(VoiidDialogTokens.topRadius))
                    .background(VoiidColor.surfaceCard)
                    .border(0.5.dp, VoiidColor.divider.copy(alpha = 0.5f), RoundedCornerShape(VoiidDialogTokens.topRadius))
                    .pointerInput(Unit) { detectTapGestures { } }   // consume surface taps
                    .imePadding(),
            ) {
                Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp)) {
                    Spacer(Modifier.height(20.dp))
                    Text(
                        title,
                        style = VoiidFont.rounded(17, FontWeight.SemiBold),
                        color = VoiidColor.textPrimary,
                    )
                    if (body != null) {
                        Spacer(Modifier.height(10.dp))
                        Text(body, style = VoiidFont.rounded(14), color = VoiidColor.textPrimary)
                    }
                    footer?.invoke(this)
                    Spacer(Modifier.height(18.dp))
                }
                Row(
                    Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    if (cancelLabel != null) {
                        DialogAction(
                            label = cancelLabel,
                            tint = VoiidColor.textSecondary,
                            enabled = !busy,
                            modifier = Modifier.weight(1f),
                        ) {
                            if (onCancel != null) onCancel() else requestClose()
                        }
                    }
                    if (confirmLabel != null && onConfirm != null) {
                        DialogAction(
                            label = confirmLabel,
                            tint = if (confirmDestructive) VoiidColor.error else VoiidColor.primary,
                            enabled = confirmEnabled && !busy,
                            showProgress = busy,
                            modifier = Modifier.weight(1f),
                        ) {
                            if (confirmDestructive) haptics.rigid()
                            onConfirm()
                        }
                    }
                }
            }
        }
    }
}

/** 48dp minimum-height text action, matching the touch-target contract. */
@Composable
private fun DialogAction(
    label: String,
    tint: Color,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    showProgress: Boolean = false,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .heightIn(min = 48.dp)
            .alpha(if (enabled) 1f else 0.5f),
        contentAlignment = Alignment.Center,
    ) {
        if (showProgress) {
            CircularProgressIndicator(color = tint, modifier = Modifier.height(20.dp).width(20.dp), strokeWidth = 2.dp)
        } else {
            TextButton(enabled = enabled, onClick = onClick) {
                Text(label, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = tint)
            }
        }
    }
}

/**
 * One full-width stacked action inside [VoiidDialogCustom] — the shape iOS confirmation
 * dialogs use when there are two or three mutually exclusive outcomes (delete-for-everyone /
 * delete-for-me). 48dp target; [destructive] renders the error colour.
 */
@Composable
fun VoiidDialogAction(
    label: String,
    modifier: Modifier = Modifier,
    destructive: Boolean = false,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    TextButton(
        enabled = enabled,
        onClick = {
            if (destructive) haptics.rigid()
            onClick()
        },
        modifier = modifier.fillMaxWidth().heightIn(min = 48.dp),
    ) {
        Text(
            label,
            style = VoiidFont.rounded(15, FontWeight.SemiBold),
            color = if (destructive) VoiidColor.error else VoiidColor.primary,
        )
    }
}

/**
 * Slot variant for dialogs whose body/actions need composables (member role menus, text entry).
 * Same surface, stroke, dismissal policy and hierarchy rules as [VoiidDialog].
 */
@Composable
fun VoiidDialogCustom(
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    backDismissable: Boolean = true,
    scrimDismissable: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    Dialog(
        onDismissRequest = { if (backDismissable) onDismissRequest() },
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
            dismissOnBackPress = false,
            dismissOnClickOutside = false,
        ),
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(scrimDismissable) {
                    detectTapGestures { if (scrimDismissable) onDismissRequest() }
                },
            contentAlignment = Alignment.Center,
        ) {
            Column(
                modifier
                    .padding(horizontal = 32.dp)
                    .widthIn(max = 380.dp)
                    .clip(RoundedCornerShape(VoiidDialogTokens.topRadius))
                    .background(VoiidColor.surfaceCard)
                    .border(0.5.dp, VoiidColor.divider.copy(alpha = 0.5f), RoundedCornerShape(VoiidDialogTokens.topRadius))
                    .pointerInput(Unit) { detectTapGestures { } }
                    .imePadding(),
            ) {
                Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
                    content()
                }
            }
        }
    }
}

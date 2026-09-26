package com.voiid.app.ui.components

import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/*
 * The iOS form field (CommunityAuthoring `ComposerField`): a small semibold label above, then
 * a soft `fieldFill` box with a 1dp `fieldBorder` hairline and 15pt rounded text. Replaces the
 * stock Material OutlinedTextField everywhere — its floating label and heavy outline are the
 * "Android look" iOS never has.
 */

/**
 * Drop-in for Material `OutlinedTextField` — same parameter names and order — so every call
 * site switches by name alone. [label] renders ABOVE the box, never floating inside it.
 */
@Composable
fun VoiidOutlinedField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    label: (@Composable () -> Unit)? = null,
    placeholder: (@Composable () -> Unit)? = null,
    prefix: (@Composable () -> Unit)? = null,
    supportingText: (@Composable () -> Unit)? = null,
    isError: Boolean = false,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    singleLine: Boolean = false,
    maxLines: Int = if (singleLine) 1 else Int.MAX_VALUE,
    minLines: Int = 1,
    @Suppress("UNUSED_PARAMETER") shape: Shape? = null,
    focusRequester: FocusRequester? = null,
    trailingLabel: (@Composable () -> Unit)? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    val border by animateColorAsState(
        when {
            isError -> VoiidColor.error
            focused -> VoiidColor.accent
            else -> VoiidColor.fieldBorder
        }, label = "fieldBorder",
    )
    val shapeR = RoundedCornerShape(VoiidRadius.md)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(7.dp)) {
        if (label != null || trailingLabel != null) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    label?.let {
                        CompositionLocalProvider(
                            LocalTextStyle provides VoiidFont.rounded(12.5f, FontWeight.SemiBold),
                            LocalContentColor provides if (isError) VoiidColor.error else VoiidColor.textSecondary,
                        ) { it() }
                    }
                }
                trailingLabel?.invoke()
            }
        }
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            enabled = enabled,
            singleLine = singleLine,
            minLines = minLines,
            maxLines = maxLines,
            keyboardOptions = keyboardOptions,
            visualTransformation = visualTransformation,
            interactionSource = interaction,
            textStyle = VoiidFont.rounded(15).copy(color = VoiidColor.textPrimary),
            cursorBrush = SolidColor(VoiidColor.accent),
            modifier = Modifier.fillMaxWidth()
                .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
                .alpha(if (enabled) 1f else 0.55f),
            decorationBox = { inner ->
                Row(
                    Modifier.fillMaxWidth().clip(shapeR).background(VoiidColor.fieldFill)
                        .border(1.dp, border, shapeR)
                        .padding(horizontal = VoiidSpacing.md, vertical = 12.dp),
                    verticalAlignment = if (singleLine) Alignment.CenterVertically else Alignment.Top,
                ) {
                    prefix?.let {
                        CompositionLocalProvider(
                            LocalTextStyle provides VoiidFont.rounded(15),
                            LocalContentColor provides VoiidColor.textSecondary,
                        ) { it() }
                        Spacer(Modifier.size(4.dp))
                    }
                    Box(Modifier.weight(1f)) {
                        if (value.isEmpty() && placeholder != null) {
                            CompositionLocalProvider(
                                LocalTextStyle provides VoiidFont.rounded(15),
                                LocalContentColor provides VoiidColor.textSecondary.copy(alpha = 0.8f),
                            ) { placeholder() }
                        }
                        inner()
                    }
                }
            },
        )
        supportingText?.let {
            Box(Modifier.padding(horizontal = 4.dp)) {
                CompositionLocalProvider(
                    LocalTextStyle provides VoiidFont.rounded(12),
                    LocalContentColor provides if (isError) VoiidColor.error else VoiidColor.textSecondary,
                ) { it() }
            }
        }
    }
}

/**
 * iOS `ComposerField`: label on the left, and — once the text is within 20% of [limit] —
 * the characters remaining on the right, amber at the cap.
 */
@Composable
fun VoiidComposerField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    limit: Int,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    singleLine: Boolean = false,
    minLines: Int = 1,
    maxLines: Int = Int.MAX_VALUE,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    focusRequester: FocusRequester? = null,
) {
    VoiidOutlinedField(
        value = value,
        onValueChange = { onValueChange(it.take(limit)) },
        modifier = modifier.fillMaxWidth(),
        enabled = enabled,
        label = { Text(label) },
        placeholder = { Text(placeholder) },
        singleLine = singleLine,
        minLines = minLines,
        maxLines = maxLines,
        keyboardOptions = keyboardOptions,
        focusRequester = focusRequester,
        trailingLabel = if (value.length >= limit * 4 / 5) {
            {
                Text("${limit - value.length}", style = VoiidFont.rounded(12, FontWeight.SemiBold),
                    color = if (value.length >= limit) VoiidColor.warning else VoiidColor.textSecondary)
            }
        } else null,
    )
}

/**
 * iOS `ComposerScaffold`: a full-screen sheet with Cancel on the left, the confirm verb (or a
 * spinner) on the right, a large-title header and subtitle, the form, and a failure banner.
 */
@Composable
fun VoiidComposerScaffold(
    title: String,
    subtitle: String,
    confirm: String,
    canConfirm: Boolean,
    busy: Boolean,
    failure: String?,
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val focus = LocalFocusManager.current
    Dialog(
        onDismissRequest = { if (!busy) onCancel() },
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        BackHandler(enabled = busy) {}
        Column(
            Modifier.fillMaxSize().background(VoiidColor.background)
                .pointerInput(Unit) { detectTapGestures(onTap = { focus.clearFocus() }) }
                .statusBarsPadding().navigationBarsPadding(),
        ) {
            Row(
                Modifier.fillMaxWidth().height(52.dp).padding(horizontal = VoiidSpacing.md),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Cancel", style = VoiidFont.rounded(17), color = VoiidColor.textSecondary,
                    modifier = Modifier.alpha(if (busy) 0.4f else 1f).softClickable(enabled = !busy) { onCancel() })
                Spacer(Modifier.weight(1f))
                if (busy) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = VoiidColor.accent)
                } else {
                    Text(confirm, style = VoiidFont.rounded(17, FontWeight.SemiBold),
                        color = if (canConfirm) VoiidColor.accentInk else VoiidColor.textSecondary,
                        modifier = Modifier.softClickable(enabled = canConfirm) { focus.clearFocus(); onConfirm() })
                }
            }
            Column(
                Modifier.weight(1f).fillMaxWidth().imePadding().verticalScroll(rememberScrollState())
                    .padding(VoiidSpacing.md),
                verticalArrangement = Arrangement.spacedBy(VoiidSpacing.lg),
            ) {
                VoiidSettingsHeader(title, subtitle = subtitle)
                content()
                failure?.let {
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(VoiidRadius.md))
                            .background(VoiidColor.error.copy(alpha = 0.10f))
                            .border(1.dp, VoiidColor.error.copy(alpha = 0.35f), RoundedCornerShape(VoiidRadius.md))
                            .padding(VoiidSpacing.md),
                        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                    ) {
                        Icon(Icons.Default.Warning, null, tint = VoiidColor.error, modifier = Modifier.size(15.dp))
                        Text(it, style = VoiidFont.rounded(13), color = VoiidColor.textPrimary)
                    }
                }
            }
        }
    }
}

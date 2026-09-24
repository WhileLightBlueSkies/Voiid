package com.voiid.app.main

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.VoiidCircleBack
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

@Composable
internal fun QrPreviewPage(
    title: String, subtitle: String, onBack: () -> Unit, busy: Boolean = false,
    inSheet: Boolean = false,
    actions: @Composable ColumnScope.() -> Unit = {},
    content: @Composable ColumnScope.() -> Unit,
) {
    BackHandler { if (!busy) onBack() }
    Column(Modifier.fillMaxSize().background(VoiidColor.background)
        .then(if (inSheet) Modifier else Modifier.statusBarsPadding().navigationBarsPadding())
        .imePadding()) {
        VoiidCircleBack(onBack = { if (!busy) onBack() })
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            QrHeading(title, subtitle)
            content()
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp), content = actions)
    }
}

@Composable
internal fun QrHeading(title: String, subtitle: String) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = VoiidFont.rounded(30, FontWeight.Bold), color = VoiidColor.textPrimary)
        Text(subtitle, style = VoiidFont.rounded(15), color = VoiidColor.textSecondary)
    }
}

@Composable
internal fun QrAction(text: String, secondary: Boolean = false, enabled: Boolean = true,
                      busy: Boolean = false, tag: String = "", onClick: () -> Unit) {
    Button(
        onClick = onClick, enabled = enabled && !busy,
        modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp).testTag(tag),
        shape = RoundedCornerShape(16.dp),
        contentPadding = PaddingValues(16.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = if (secondary) VoiidColor.surfaceRaised else VoiidColor.primary,
            contentColor = if (secondary) VoiidColor.textPrimary else VoiidColor.textOnPrimary),
    ) {
        if (busy) CircularProgressIndicator(Modifier.size(22.dp), color = VoiidColor.textOnPrimary, strokeWidth = 2.dp)
        else Text(text, style = VoiidFont.rounded(16, FontWeight.SemiBold))
    }
}

@Composable
internal fun QrIdentityAvatar(photo: String?, name: String) {
    Box(Modifier.size(88.dp).clip(RoundedCornerShape(24.dp)).background(VoiidColor.primary), contentAlignment = Alignment.Center) {
        if (!photo.isNullOrBlank()) ProfileAvatar(photo, name, 88.dp, fillsFrame = true)
        else Text(name.split(" ").filter { it.isNotBlank() }.take(2).map { it.first() }.joinToString("").uppercase(),
            style = VoiidFont.rounded(31, FontWeight.Bold), color = VoiidColor.textOnPrimary)
    }
}

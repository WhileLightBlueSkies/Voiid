package com.voiid.app.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.launch

/**
 * Searchable country picker as a **native** Material3 modal bottom sheet (the Android-native
 * counterpart to the iOS `.sheet`). Brand-styled rows + search.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CountryPickerSheet(
    selected: Country,
    onSelect: (Country) -> Unit,
    onDismiss: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    val results = remember(query) {
        if (query.isBlank()) CountryStore.all
        else CountryStore.all.filter {
            it.name.contains(query, ignoreCase = true) || it.dialCode.contains(query)
        }
    }

    fun choose(c: Country) {
        haptics.selection()
        onSelect(c)
        scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = VoiidColor.background,
        dragHandle = null,   // iOS `.sheet` shows no grabber — match it
    ) {
        Column(Modifier.fillMaxHeight(0.92f)) {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 24.dp, bottom = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Select country", style = VoiidFont.rounded(18, FontWeight.SemiBold), color = VoiidColor.textPrimary)
                Spacer(Modifier.weight(1f))
                Icon(
                    Icons.Default.Cancel, "Close",
                    tint = VoiidColor.textSecondary.copy(alpha = 0.6f),
                    modifier = Modifier
                        .size(26.dp)
                        .clip(RoundedCornerShape(VoiidRadius.pill))
                        .clickable { scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() } },
                )
            }

            // Search field (brand styled)
            val searchShape = RoundedCornerShape(VoiidRadius.md)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp)
                    .padding(bottom = 8.dp)
                    .height(48.dp)
                    .clip(searchShape)
                    .background(VoiidColor.fieldFill)
                    .border(1.dp, VoiidColor.fieldBorder, searchShape)
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Default.Search, null, tint = VoiidColor.placeholder, modifier = Modifier.height(20.dp))
                BasicTextField(
                    value = query,
                    onValueChange = { query = it },
                    singleLine = true,
                    textStyle = VoiidFont.rounded(16).merge(TextStyle(color = VoiidColor.textPrimary)),
                    cursorBrush = SolidColor(VoiidColor.primary),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text),
                    modifier = Modifier.weight(1f),
                    decorationBox = { inner ->
                        Box(contentAlignment = Alignment.CenterStart) {
                            if (query.isEmpty()) {
                                Text("Search country or code", style = VoiidFont.rounded(16), color = VoiidColor.placeholder)
                            }
                            inner()
                        }
                    },
                )
                if (query.isNotEmpty()) {
                    Icon(
                        Icons.Default.Cancel, "Clear", tint = VoiidColor.placeholder,
                        modifier = Modifier.size(18.dp).clickable { query = "" },
                    )
                }
            }

            // List
            LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
                items(results, key = { it.id }) { c ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(56.dp)
                            .clickable { choose(c) }
                            .padding(horizontal = 24.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Text(c.flag, fontSize = 24.sp)
                        Text(c.name, style = VoiidFont.rounded(17), color = VoiidColor.textPrimary)
                        Spacer(Modifier.weight(1f))
                        Text(c.dialCode, style = VoiidFont.rounded(16), color = VoiidColor.textSecondary)
                        if (c.id == selected.id) {
                            Icon(Icons.Default.Check, null, tint = VoiidColor.primary, modifier = Modifier.height(18.dp))
                        }
                    }
                    HorizontalDivider(
                        color = VoiidColor.divider.copy(alpha = 0.4f),
                        modifier = Modifier.padding(start = 24.dp),
                    )
                }
            }
        }
    }
}

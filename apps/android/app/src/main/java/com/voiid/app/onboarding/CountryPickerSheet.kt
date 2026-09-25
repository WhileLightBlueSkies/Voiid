package com.voiid.app.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
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
import androidx.compose.material3.Text
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
import com.voiid.app.ui.components.noRippleClickable
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
    androidx.compose.runtime.CompositionLocalProvider(com.voiid.app.ui.theme.LocalVoiidDark provides com.voiid.app.ui.theme.LocalVoiidDark.current) {
        DarkCountryPickerSheet(selected, onSelect, onDismiss)
    }
}

@Composable
private fun DarkCountryPickerSheet(selected: Country, onSelect: (Country) -> Unit, onDismiss: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    val listState = androidx.compose.foundation.lazy.rememberLazyListState(
        initialFirstVisibleItemIndex = CountryStore.all.indexOfFirst { it.id == selected.id }.coerceAtLeast(0),
    )
    var query by remember { mutableStateOf("") }
    val results = remember(query) {
        if (query.isBlank()) CountryStore.all
        else CountryStore.all.filter {
            // Name, EXACT iso code, or a dial-code PREFIX with any leading "+" stripped.
            // Android matched only name and `dialCode.contains(query)`, so "IN" found nothing,
            // "+91" found nothing, and "1" matched +91/+61/+371 and about a hundred others.
            val q = query.trim().lowercase()
            val digits = q.removePrefix("+")
            it.name.contains(q, ignoreCase = true) ||
                it.id.lowercase() == q ||
                (digits.isNotEmpty() && it.dialCode.removePrefix("+").startsWith(digits))
        }
    }

    androidx.compose.runtime.LaunchedEffect(query) {
        listState.scrollToItem(if (query.isBlank()) CountryStore.all.indexOfFirst { it.id == selected.id }.coerceAtLeast(0) else 0)
    }
    androidx.compose.runtime.LaunchedEffect(listState.isScrollInProgress) {
        if (listState.isScrollInProgress) focus.clearFocus()
    }

    fun choose(c: Country) {
        focus.clearFocus()
        haptics.selection()
        onSelect(c)
        onDismiss()
    }

    // Near-full presentation, no grabber — matches the iOS country sheet.
    com.voiid.app.ui.components.VoiidSheet(
        visible = true,
        onDismiss = onDismiss,
        detents = listOf(com.voiid.app.ui.components.VoiidDetent.Large),
        showHandle = false,
    ) {
        Column(Modifier.fillMaxHeight().background(VoiidColor.background).imePadding()) {
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
                        .noRippleClickable { onDismiss() },
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
                    cursorBrush = SolidColor(VoiidColor.accent),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text, autoCorrectEnabled = false, capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.None),
                    modifier = Modifier.weight(1f),
                    decorationBox = { inner ->
                        Box(contentAlignment = Alignment.CenterStart) {
                            if (query.isEmpty()) {
                                Text("Country, code or +dial", style = VoiidFont.rounded(16), color = VoiidColor.placeholder)
                            }
                            inner()
                        }
                    },
                )
                if (query.isNotEmpty()) {
                    Icon(
                        Icons.Default.Cancel, "Clear", tint = VoiidColor.placeholder,
                        modifier = Modifier.size(18.dp).noRippleClickable { query = "" },
                    )
                }
            }

            // List
            // A search that matches nothing must SAY so. An empty list reads as a screen
            // that failed to load.
            if (results.isEmpty()) {
                Column(
                    Modifier.fillMaxWidth().weight(1f).padding(top = 48.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Icon(Icons.Default.Search, null, tint = VoiidColor.placeholder,
                        modifier = Modifier.size(32.dp))
                    Text("No countries match \u201C$query\u201D", style = VoiidFont.rounded(15),
                        color = VoiidColor.textSecondary)
                }
            } else LazyColumn(Modifier.fillMaxWidth().weight(1f), state = listState) {
                items(results, key = { it.id }) { c ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(56.dp)
                            .noRippleClickable { choose(c) }
                            .padding(horizontal = 24.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Text(c.flag, fontSize = 24.sp)
                        Text(c.name, style = VoiidFont.rounded(17), color = VoiidColor.textPrimary, modifier = Modifier.weight(1f), maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                        Text(c.dialCode, style = VoiidFont.rounded(16), color = VoiidColor.textSecondary)
                        Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) {
                            if (c.id == selected.id) Icon(Icons.Default.Check, "Selected", tint = VoiidColor.accent, modifier = Modifier.size(18.dp))
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

package com.voiid.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.delay

/**
 * The one search field behind every audited search surface (New Chat, New Group, Communities,
 * country/GIF pickers). Contract from the component backlog:
 *
 *  - 48dp height, 12dp radius; magnifier + clear affordances.
 *  - Focused border so the active field is findable at a glance.
 *  - ImeAction.Search wired through [onSearch].
 *  - Optional [debounce] hook: [onQueryChanged] fires only after typing settles, so callers can
 *    hit the network per pause instead of per keystroke. Pass 0 to get every keystroke.
 */
@Composable
fun VoiidSearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "Search",
    debounceMs: Long = 250,
    onQueryDebounced: ((String) -> Unit)? = null,
    onSearch: (() -> Unit)? = null,
) {
    var focused by remember { mutableStateOf(false) }

    LaunchedEffect(query, debounceMs) {
        if (onQueryDebounced == null || debounceMs <= 0L) return@LaunchedEffect
        if (query.isBlank()) return@LaunchedEffect
        delay(debounceMs)
        onQueryDebounced(query)
    }

    val shape = RoundedCornerShape(12.dp)
    Row(
        modifier
            .fillMaxWidth()
            .height(48.dp)
            .clip(shape)
            .background(VoiidColor.fieldFill)
            .border(
                1.dp,
                if (focused) VoiidColor.primary else VoiidColor.fieldBorder,
                shape,
            )
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Search, null, tint = VoiidColor.placeholder, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        BasicTextField(
            value = query,
            onValueChange = onQueryChange,
            singleLine = true,
            textStyle = VoiidFont.rounded(15).merge(TextStyle(color = VoiidColor.textPrimary)),
            cursorBrush = SolidColor(VoiidColor.primary),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { onSearch?.invoke() }),
            modifier = Modifier
                .weight(1f)
                .onFocusChanged { focused = it.isFocused },
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.CenterStart) {
                    if (query.isEmpty()) {
                        Text(placeholder, style = VoiidFont.rounded(15), color = VoiidColor.placeholder)
                    }
                    inner()
                }
            },
        )
        if (query.isNotEmpty()) {
            Spacer(Modifier.width(8.dp))
            Icon(
                Icons.Default.Close, "Clear",
                tint = VoiidColor.placeholder,
                modifier = Modifier
                    .size(18.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.fieldBorder.copy(alpha = 0.35f))
                    .clickableNoRipple { onQueryChange("") }
                    .padding(2.dp),
            )
        }
    }
}

private fun Modifier.clickableNoRipple(onClick: () -> Unit): Modifier =
    clickable(
        interactionSource = androidx.compose.foundation.interaction.MutableInteractionSource(),
        indication = null,
    ) { onClick() }

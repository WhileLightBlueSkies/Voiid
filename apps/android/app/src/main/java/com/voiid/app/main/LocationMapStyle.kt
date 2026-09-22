package com.voiid.app.main

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import com.google.android.gms.maps.model.MapStyleOptions
import com.voiid.app.ui.theme.LocalVoiidDark

/** Keep the same SDK style object across countdown ticks and incoming location fixes. */
@Composable
internal fun rememberLocationMapStyle(): MapStyleOptions {
    val dark = LocalVoiidDark.current
    return remember(dark) { MapStyleOptions(if (dark) VOIID_MAP_STYLE_DARK else VOIID_MAP_STYLE_LIGHT) }
}

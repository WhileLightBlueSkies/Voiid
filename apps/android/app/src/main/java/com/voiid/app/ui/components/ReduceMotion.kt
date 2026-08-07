package com.voiid.app.ui.components

import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

/**
 * Whether the user has asked the system to reduce animation.
 *
 * Android has no single "Reduce Motion" switch the way iOS does. What it has is
 * `ANIMATOR_DURATION_SCALE` — set to 0 by Settings > Accessibility > "Remove animations", and
 * also by developers in Developer Options. Both mean the same thing to us: do not move large
 * objects across the screen.
 *
 * ## What this is NOT for
 * Reduced motion does not mean NO feedback. It means a gentler, non-vestibular equivalent.
 * Press states, colour changes and small-element scales stay exactly as they are — removing
 * them would cost information and calm nobody. This gates the motion that TRAVELS: a list
 * reflowing every row, a full-width banner sliding down over content.
 *
 * Read once per composition rather than observed. The setting changes about as often as a
 * device is reconfigured, and watching a ContentObserver for it on every screen would cost
 * more than it could ever save.
 */
@Composable
fun reduceMotionEnabled(): Boolean {
    val resolver = LocalContext.current.contentResolver
    return remember(resolver) {
        runCatching {
            Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
        }.getOrDefault(false)
    }
}

package com.voiid.app.main.games

import android.content.Context
import android.provider.Settings

/**
 * Whether the player has asked the system to reduce motion.
 *
 * The Android counterpart to iOS's `UIAccessibility.isReduceMotionEnabled`, which this app reads
 * for the same decisions (docs/games/CROSS_CUTTING.md §13).
 *
 * ANDROID HAS NO DIRECT EQUIVALENT, so this reads the animator duration scale instead —
 * Settings > Developer options > "Animator duration scale: off", and, more importantly, what
 * Android's own accessibility "Remove animations" toggle sets. A scale of 0 means the system has
 * been told animations should not play, and that is the closest thing to an honest answer the
 * platform offers. Google's own Material components make the same read for the same reason.
 *
 * READ PER CALL, NOT CACHED. The setting can change while the app is in the background, and a
 * value cached at process start would leave a motion-sensitive player with the animations they
 * just turned off until they force-quit. It is a single Settings lookup against an in-memory
 * cache on the system side; a per-match read costs nothing, and this is deliberately NOT called
 * per frame — call sites read it once when a match or an animation begins.
 */
object ReduceMotion {
    fun isEnabled(context: Context): Boolean = runCatching {
        Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }.getOrDefault(false)
}

package com.voiid.app.ui.theme

import androidx.compose.ui.unit.dp

/** Spacing scale (Master Spec Section 6.3) — mirrors iOS `VoiidSpacing`. */
object VoiidSpacing {
    val xs = 4.dp
    val sm = 8.dp
    val md = 16.dp
    val lg = 24.dp
    val xl = 32.dp
    val xxl = 48.dp
}

/** Corner radii (Master Spec Section 6.4) — mirrors iOS `VoiidRadius`. */
object VoiidRadius {
    val sm = 8.dp
    val md = 12.dp
    val lg = 16.dp
    val pill = 999.dp
}

/**
 * Ludo geometry + motion constants (LUDO_GAME_SPEC.md §2.2, §12–§15). Mirrors iOS
 * `LudoDimens`/`LudoMotion` and packages/design-tokens/tokens.json → dimension/motion.
 */
object LudoDimens {
    val boardCornerRadius = 0.dp
    const val perimeterStrokeLightDp = 3f
    const val perimeterStrokeDarkDp = 3.5f
    val boardContentInset = 0.dp
    const val cellBorderLightDp = 0.75f
    const val cellBorderDarkDp = 1f
    const val cellCornerRadiusFactor = 0f
    const val yardPocketRadiusFactor = 0f
    /** Resting-circle radius for a yard slot, as a fraction of one cell. */
    const val yardSlotRadiusFactor = 0.46f
    const val safeStarRadiusFactor = 0.27f

    // Pods carry only a chip and a username, so they stay small and let the board dominate —
    // the name is a label beside the board, never a headline.
    val podWidthStandard = 120.dp
    val podHeightStandard = 36.dp
    val podWidthCompact = 108.dp
    val podHeightCompact = 32.dp
    val podCornerRadius = 10.dp
    val podChipStandard = 16.dp
    val podChipCompact = 14.dp
    val timerRingStandard = 24.dp
    val timerRingCompact = 21.dp
    val timerRingStroke = 2.dp

    val dieSizeStandard = 64.dp
    val dieSizeCompact = 44.dp
    val dieSizeTablet = 72.dp
    val dieHitTarget = 72.dp
}

object LudoMotion {
    const val BORDER_SWEEP_MS = 360
    const val DIE_RELOCATE_MS = 120
    /**
     * Hold after a roll settles before a forced (single-legal-token) move plays itself, so the
     * number stays readable before the board moves under it.
     */
    const val FORCED_MOVE_HOLD_MS = 420L
    const val PIP_CROSS_FADE_MS = 120
    const val ROLL_TOTAL_MS = 940
    const val HOP_MS = 120
    const val HOP_STAGGER_MS = 92
    const val FAST_FORWARD_MS = 90
    const val HALO_BREATHE_MS = 520
    const val CAPTURE_SCALE_MS = 150
    const val CAPTURE_RETURN_MS = 260
    const val FINISH_SHRINK_MS = 240
    const val FINISH_PULSE_MS = 220
    const val RESULT_RIPPLE_MS = 420

    /** §12.3 serialized sequence: sweep 0–360, die relocate/pips 360–480, open at 480. */
    const val TRANSITION_MS = 480

    // Cubic Bézier control points, shared with the tokens file.
    val BorderSweepEasing = CubicEasing(0.22f, 0f, 0f, 1f)
    val DieRelocateEasing = CubicEasing(0.20f, 0f, 0f, 1f)



    /** Minimal cubic-Bézier evaluator so both platforms use the same curves. */
    class CubicEasing(private val x1: Float, private val y1: Float, private val x2: Float, private val y2: Float) {
        fun transform(t: Float): Float {
            if (t <= 0f) return 0f
            if (t >= 1f) return 1f
            var lo = 0f
            var hi = 1f
            var mid = t
            repeat(24) {
                mid = (lo + hi) / 2f
                val x = bezier(mid, x1, x2)
                if (x < t) lo = mid else hi = mid
            }
            return bezier(mid, y1, y2)
        }

        private fun bezier(t: Float, p1: Float, p2: Float): Float {
            val u = 1f - t
            return 3f * u * u * t * p1 + 3f * u * t * t * p2 + t * t * t
        }
    }
}

/** Theme convenience for non-composable call sites (canvas painters). */
@androidx.compose.runtime.Composable
fun isLightTheme(): Boolean = !com.voiid.app.ui.theme.LocalVoiidDark.current

package com.voiid.app.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.voiid.app.R

/**
 * Typography (Master Spec Section 6.2) — mirrors iOS `VoiidFont`.
 *
 *  - Logo wordmark ("voiid") = Urbanist Bold (exact Figma lettering).
 *  - Everything else = Nunito — the rounded face that matches iOS's "SF Pro Rounded"
 *    friendly geometry. (Both shipped as bundled variable fonts in res/font.)
 */

// Variable fonts: force the `wght` axis explicitly per weight so SemiBold/Bold render with the
// exact same heaviness as iOS (not flattened to the font's default Regular instance on some devices).
@OptIn(ExperimentalTextApi::class)
private fun nunito(weight: FontWeight, wght: Int) =
    Font(R.font.nunito_variable, weight, variationSettings = FontVariation.Settings(FontVariation.weight(wght)))

@OptIn(ExperimentalTextApi::class)
private fun urbanist(weight: FontWeight, wght: Int) =
    Font(R.font.urbanist_variable, weight, variationSettings = FontVariation.Settings(FontVariation.weight(wght)))

val Nunito = FontFamily(
    nunito(FontWeight.Normal, 400),
    nunito(FontWeight.Medium, 500),
    nunito(FontWeight.SemiBold, 600),
    nunito(FontWeight.Bold, 700),
)

val Urbanist = FontFamily(
    urbanist(FontWeight.SemiBold, 600),
    urbanist(FontWeight.Bold, 700),
)

object VoiidFont {
    /** Nunito (rounded) at the spec's type scale. */
    fun rounded(size: Int, weight: FontWeight = FontWeight.Normal): TextStyle =
        TextStyle(fontFamily = Nunito, fontSize = size.sp, fontWeight = weight)

    /** Urbanist Bold — ONLY for the "voiid" logo wordmark. */
    fun logo(size: Int): TextStyle =
        TextStyle(fontFamily = Urbanist, fontSize = size.sp, fontWeight = FontWeight.Bold)

    val display  = rounded(34, FontWeight.Bold)
    val title    = rounded(22, FontWeight.SemiBold)
    val headline = rounded(17, FontWeight.SemiBold)
    val body     = rounded(17, FontWeight.Normal)
    val callout  = rounded(16, FontWeight.Normal)
    val subhead  = rounded(15, FontWeight.Normal)
    val footnote = rounded(13, FontWeight.Normal)
    val caption  = rounded(12, FontWeight.Normal)
}

/** Material3 Typography so any default Text() also renders in Nunito. */
val VoiidTypography = Typography().run {
    copy(
        displayLarge = displayLarge.copy(fontFamily = Nunito),
        displayMedium = displayMedium.copy(fontFamily = Nunito),
        displaySmall = displaySmall.copy(fontFamily = Nunito),
        headlineLarge = headlineLarge.copy(fontFamily = Nunito),
        headlineMedium = headlineMedium.copy(fontFamily = Nunito),
        headlineSmall = headlineSmall.copy(fontFamily = Nunito),
        titleLarge = titleLarge.copy(fontFamily = Nunito),
        titleMedium = titleMedium.copy(fontFamily = Nunito),
        titleSmall = titleSmall.copy(fontFamily = Nunito),
        bodyLarge = bodyLarge.copy(fontFamily = Nunito),
        bodyMedium = bodyMedium.copy(fontFamily = Nunito),
        bodySmall = bodySmall.copy(fontFamily = Nunito),
        labelLarge = labelLarge.copy(fontFamily = Nunito),
        labelMedium = labelMedium.copy(fontFamily = Nunito),
        labelSmall = labelSmall.copy(fontFamily = Nunito),
    )
}

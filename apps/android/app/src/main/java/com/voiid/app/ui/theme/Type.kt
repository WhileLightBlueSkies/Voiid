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

    /**
     * The same face at a FRACTIONAL size, for the handful of places iOS specifies one
     * (`VoiidFont.rounded(12.5)` on the community write-error banner) and for sizes derived
     * from a container — `CommunityAvatar` sets its initials at 0.38 × the circle.
     *
     * Rounding those to the nearest whole sp instead was the alternative and is worse: it
     * makes a 26dp face pile and a 64dp card disagree about weight-to-size ratio, which is
     * visible precisely where the two sit on the same screen.
     */
    fun rounded(size: Float, weight: FontWeight = FontWeight.Normal): TextStyle =
        TextStyle(fontFamily = Nunito, fontSize = size.sp, fontWeight = weight)

    /** Urbanist Bold — ONLY for the "voiid" logo wordmark. */
    fun logo(size: Int): TextStyle =
        TextStyle(fontFamily = Urbanist, fontSize = size.sp, fontWeight = FontWeight.Bold)

    /**
     * SEMANTIC styles with explicit line heights and tracking — the audit's P2 ask. Sizes are
     * the iOS scale (34/22/17/17/16/15/13/12); line height and letter spacing follow iOS
     * display-type convention: leading tightens as sizes grow, and NEGATIVE tracking applies
     * from headline upward because letters read progressively further apart as they grow
     * (-0.018em at 30sp is already used on the onboarding title). Body and below keep default
     * spacing — tightening small text harms legibility.
     */
    val display  = rounded(34, FontWeight.Bold).copy(lineHeight = 38.sp, letterSpacing = (-0.4).sp)
    val title    = rounded(22, FontWeight.SemiBold).copy(lineHeight = 27.sp, letterSpacing = (-0.3).sp)
    val headline = rounded(17, FontWeight.SemiBold).copy(lineHeight = 22.sp, letterSpacing = (-0.2).sp)
    val body     = rounded(17, FontWeight.Normal).copy(lineHeight = 23.sp)
    val callout  = rounded(16, FontWeight.Normal).copy(lineHeight = 21.sp)
    val subhead  = rounded(15, FontWeight.Normal).copy(lineHeight = 20.sp)
    val footnote = rounded(13, FontWeight.Normal).copy(lineHeight = 17.sp)
    val caption  = rounded(12, FontWeight.Normal).copy(lineHeight = 16.sp)
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

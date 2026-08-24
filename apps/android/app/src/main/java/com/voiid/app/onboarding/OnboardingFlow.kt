@file:OptIn(androidx.compose.animation.ExperimentalSharedTransitionApi::class)

package com.voiid.app.onboarding

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibilityScope
import androidx.compose.animation.ExperimentalSharedTransitionApi
import androidx.compose.animation.SharedTransitionLayout
import androidx.compose.animation.SharedTransitionScope
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.R
import com.voiid.app.model.AppSession
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.delay

/** Splash → Terms → Permissions → Phone → OTP → Signup → Create Profile → main app. */

enum class OnbStep { TERMS, PERMISSIONS, PHONE, OTP, VERIFIED, SIGNUP, PROFILE }

// Scopes for the splash→Terms shared-element logo glide, provided around the
// outer (splash) AnimatedContent so the splash + Terms LogoMarks can be matched.
private val LocalSharedTransitionScope = staticCompositionLocalOf<SharedTransitionScope?> { null }
private val LocalOnbAnimatedScope = staticCompositionLocalOf<AnimatedVisibilityScope?> { null }

/** Tag the logo as the shared "voiidLogo" element so it GLIDES from the splash
 *  centre to its Terms position (Compose equivalent of iOS matchedGeometryEffect).
 *  No-op when the scopes aren't present. */
@OptIn(ExperimentalSharedTransitionApi::class)
@Composable
private fun Modifier.voiidSharedLogo(): Modifier {
    val sts = LocalSharedTransitionScope.current ?: return this
    val avs = LocalOnbAnimatedScope.current ?: return this
    return with(sts) {
        this@voiidSharedLogo.sharedElement(
            rememberSharedContentState(key = "voiidLogo"),
            animatedVisibilityScope = avs,
        )
    }
}

@OptIn(ExperimentalSharedTransitionApi::class)
@Composable
fun OnboardingFlow(session: AppSession) {
    var showSplash by remember { mutableStateOf(true) }
    var stack by remember { mutableStateOf(listOf(OnbStep.TERMS)) }
    var phone by remember { mutableStateOf("") }            // E.164, set by PhoneScreen
    var verificationId by remember { mutableStateOf("") }   // Firebase verificationId from sendCode
    // Identity half from the Signup step, handed forward; the profile step performs the single
    // server write. Mirrors iOS `ProfileDraft`.
    var signupDraft by remember { mutableStateOf(SignupDraft()) }
    // Which way Verified continues: true = returning user straight into the app,
    // false = new user continuing to Signup.
    var verifiedEntersApp by remember { mutableStateOf(false) }
    val current = stack.last()
    val reduceMotion = com.voiid.app.ui.components.reduceMotionEnabled()

    fun push(step: OnbStep) { stack = stack + step }
    fun pop() { if (stack.size > 1) stack = stack.dropLast(1) }

    // Verified is excluded: the moment is over — there is nothing to go back TO, because the
    // number is verified. Mirrors iOS `navigationBarBackButtonHidden`.
    BackHandler(enabled = stack.size > 1 && current != OnbStep.VERIFIED) { pop() }

    LaunchedEffect(Unit) {
        // 1.2s — long enough to read the mark; past that it reads as a load screen. iOS.
        delay(1200)
        showSplash = false
    }

    SharedTransitionLayout(Modifier.fillMaxSize().background(VoiidColor.background)) {
        // Splash ↔ onboarding cross-fade. The "voiidLogo" shared element glides the
        // wordmark from the splash centre up to the Terms logo across this boundary.
        // NO ANIMATION ON THE HANDOFF, deliberately — a plain cut. The old shared-element
        // glide rasterised text mid-flight and read as a loading state (see the iOS note).
        AnimatedContent(
            targetState = showSplash,
            transitionSpec = { fadeIn(tween(1)) togetherWith fadeOut(tween(1)) },
            label = "splashToOnboarding",
        ) { splash ->
            CompositionLocalProvider(
                LocalSharedTransitionScope provides this@SharedTransitionLayout,
                LocalOnbAnimatedScope provides this@AnimatedContent,
            ) {
                if (splash) {
                    SplashScreen()
                } else {
                    // Onboarding step host.
                    AnimatedContent(
                        targetState = current,
                        transitionSpec = {
                            // Hoisted read: the helper is @Composable; transitionSpec is not.
                            val rm = reduceMotion
                            val forward = targetState.ordinal > initialState.ordinal
                            if (rm) {
                                // Reduce Motion: opacity feedback only — nothing travels.
                                fadeIn(tween(180)) togetherWith fadeOut(tween(180))
                            } else {
                                val w = 300
                                (slideInHorizontally { if (forward) w else -w } + fadeIn()) togetherWith
                                    (slideOutHorizontally { if (forward) -w else w } + fadeOut())
                            }
                        },
                        label = "onboardingStep",
                    ) { step ->
                        when (step) {
                            OnbStep.TERMS -> WelcomeTermsScreen(
                                onContinue = { push(OnbStep.PERMISSIONS) },
                            )
                            OnbStep.PERMISSIONS -> PermissionsScreen(onContinue = { push(OnbStep.PHONE) })
                            OnbStep.PHONE -> PhoneScreen(onBack = ::pop, onContinue = { e164, vid -> phone = e164; verificationId = vid; push(OnbStep.OTP) })
                            OnbStep.OTP -> OtpScreen(
                                session = session,
                                phoneE164 = phone,
                                verificationId = verificationId,
                                onBack = ::pop,
                                onContinue = { verifiedEntersApp = false; push(OnbStep.VERIFIED) },
                                // Both successful OTP exits route through Verified rather than
                                // jumping straight on: the code being accepted is the moment
                                // the account becomes real, and login/E2E bootstrap are still
                                // settling — the confirmation turns that wait into the honest
                                // version of a loading state. Mirrors iOS.
                                onVerifiedExistingUser = { verifiedEntersApp = true; push(OnbStep.VERIFIED) },
                            )
                            OnbStep.VERIFIED -> VerifiedScreen(onFinished = {
                                if (verifiedEntersApp) session.completeOnboarding() else push(OnbStep.SIGNUP)
                            })
                            OnbStep.SIGNUP -> SignupScreen(
                                session = session,
                                phone = phone,
                                onBack = ::pop,
                                onContinue = { draft -> signupDraft = draft; push(OnbStep.PROFILE) },
                            )
                            OnbStep.PROFILE -> CreateProfileScreen(
                                session = session,
                                draft = signupDraft,
                                onBack = ::pop,
                                onFinish = { session.completeOnboarding() },
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Splash (Urbanist logomark, embossed on the Voiid ground)

@Composable
fun SplashScreen() {
    val cfg = LocalConfiguration.current
    val ellipse = (cfg.screenWidthDp * (325f / 402f)).dp
    var appear by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(
        targetValue = if (appear) 1f else 0.92f,
        animationSpec = spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessLow),
        label = "splashScale",
    )
    val opacity by animateFloatAsState(
        targetValue = if (appear) 1f else 0f,
        animationSpec = spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessLow),
        label = "splashOpacity",
    )
    LaunchedEffect(Unit) { appear = true }

    Box(Modifier.fillMaxSize().background(VoiidColor.background), contentAlignment = Alignment.Center) {
        LogoMark(
            size = ellipse,
            modifier = Modifier.graphicsLayer { scaleX = scale; scaleY = scale; alpha = opacity },
        )
    }
}

// MARK: - Terms & Conditions


// MARK: - Shared logo mark — PLACEHOLDER until the real art lands

/**
 * The brand mark.
 *
 * PLACEHOLDER: the old baked image was removed for the rebrand. Drawn as type rather than left
 * as an empty `painterResource`, which would throw at runtime on the FIRST screen a new user
 * sees. Twin of iOS `BrandWordmark` in DesignSystem/BrandMark.swift.
 *
 * WHEN THE REAL LOGO ARRIVES: drop it at `res/drawable-nodpi/voiid_logomark.png` (or as a
 * vector at `res/drawable/voiid_logomark.xml`) and restore the `Image(painterResource(...))`
 * body. Every call site goes through this one composable, so nothing else changes.
 *
 * The new art must work on BOTH grounds — white and Voiid Black. The old one was near-white
 * and would vanish on the new light theme.
 */
@Composable
fun LogoMark(size: Dp, modifier: Modifier = Modifier) {
    Text(
        "voiid",
        style = VoiidFont.logo((size.value * 0.30f).toInt()),
        color = VoiidColor.primary,
        modifier = modifier,
    )
}

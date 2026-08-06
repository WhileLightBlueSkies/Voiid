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

enum class OnbStep { TERMS, PERMISSIONS, PHONE, OTP, SIGNUP, PROFILE }

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
    val current = stack.last()

    fun push(step: OnbStep) { stack = stack + step }
    fun pop() { if (stack.size > 1) stack = stack.dropLast(1) }

    BackHandler(enabled = stack.size > 1) { pop() }

    LaunchedEffect(Unit) {
        delay(1900)
        showSplash = false
    }

    SharedTransitionLayout(Modifier.fillMaxSize().background(VoiidColor.background)) {
        // Splash ↔ onboarding cross-fade. The "voiidLogo" shared element glides the
        // wordmark from the splash centre up to the Terms logo across this boundary.
        AnimatedContent(
            targetState = showSplash,
            transitionSpec = { fadeIn(tween(500)) togetherWith fadeOut(tween(500)) },
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
                            val forward = targetState.ordinal > initialState.ordinal
                            val w = 300
                            (slideInHorizontally { if (forward) w else -w } + fadeIn()) togetherWith
                                (slideOutHorizontally { if (forward) -w else w } + fadeOut())
                        },
                        label = "onboardingStep",
                    ) { step ->
                        when (step) {
                            OnbStep.TERMS -> TermsScreen(onContinue = { push(OnbStep.PERMISSIONS) })
                            OnbStep.PERMISSIONS -> PermissionsScreen(onContinue = { push(OnbStep.PHONE) })
                            OnbStep.PHONE -> PhoneScreen(onBack = ::pop, onContinue = { e164, vid -> phone = e164; verificationId = vid; push(OnbStep.OTP) })
                            OnbStep.OTP -> OtpScreen(session = session, phoneE164 = phone, verificationId = verificationId, onBack = ::pop, onContinue = { push(OnbStep.SIGNUP) })
                            OnbStep.SIGNUP -> SignupScreen(session = session, phone = phone, onBack = ::pop, onContinue = { push(OnbStep.PROFILE) })
                            OnbStep.PROFILE -> CreateProfileScreen(session = session, onBack = ::pop, onFinish = { session.completeOnboarding() })
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
            modifier = Modifier
                .voiidSharedLogo()
                .graphicsLayer { scaleX = scale; scaleY = scale; alpha = opacity },
        )
    }
}

// MARK: - Terms & Conditions

/**
 * The consent screen — and, since this is where the affirmative action actually happens,
 * the DPDP s.5/s.6 surface of the whole app.
 *
 * WHAT CHANGED AND WHY
 * --------------------
 * "Terms & Conditions" and "Privacy Policy" used to be inert spans inside one
 * `buildAnnotatedString`: users ticked a box agreeing to two documents they could not open,
 * and no document existed to open. Both halves are fixed — the documents are bundled
 * (`com.voiid.app.legal.LegalDocuments`) and both phrases are now real links.
 *
 * The tick is also RECORDED now. `POST /users/consent` had existed for months with zero
 * callers on either platform, so `consent_given_at` was null for every account ever
 * created. It cannot be posted from here — there is no account and no token until several
 * screens later — so the decision is stored locally the moment it is made and flushed once
 * an account exists (see `ConsentService`).
 *
 * "I already have an account" deliberately does not record consent: someone signing back in
 * has not been shown this notice as a decision. They are caught by the backfill prompt after
 * sign-in (`MainActivity.VoiidRoot`), which asks properly rather than assuming.
 */
@Composable
fun TermsScreen(onContinue: () -> Unit) {
    val cfg = LocalConfiguration.current
    val haptics = LocalVoiidHaptics.current
    val context = androidx.compose.ui.platform.LocalContext.current
    var agreed by remember { mutableStateOf(false) }
    var contentIn by remember { mutableStateOf(false) }
    /** Set by tapping a link in the consent line. Rendered in place of this screen rather
     *  than over it: the onboarding host is a single AnimatedContent with no dialog layer,
     *  and a document is a full read, not a peek. */
    var openDocument by remember { mutableStateOf<com.voiid.app.legal.LegalDocument?>(null) }

    /**
     * Ticking IS the consent, so it is recorded here rather than on Continue: a user who
     * ticks and then abandons the flow still ticked, and a process death between the two
     * must not lose the record. Un-ticking clears it — a retracted tick is an ABSENCE of
     * consent, not a withdrawal, and posting it later would manufacture agreement.
     */
    fun setAgreed(next: Boolean) {
        agreed = next
        if (next) {
            com.voiid.app.net.ConsentService.recordLocalConsent(
                context = context,
                purposes = com.voiid.app.legal.LegalDocuments.purposes.associate { it.id to true },
            )
        } else {
            com.voiid.app.net.ConsentService.clearLocalConsent(context)
        }
    }

    val document = openDocument
    if (document != null) {
        com.voiid.app.main.LegalDocumentScreen(document = document, onBack = { openDocument = null })
        return
    }
    val contentAlpha by animateFloatAsState(if (contentIn) 1f else 0f, tween(450), label = "termsAlpha")
    val contentOffset by animateFloatAsState(if (contentIn) 0f else 16f, tween(450), label = "termsOffset")
    LaunchedEffect(Unit) { delay(250); contentIn = true }

    Box(Modifier.fillMaxSize().background(VoiidColor.background)) {
        Column(
            modifier = Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(60.dp))
            LogoMark(size = (cfg.screenWidthDp * (300f / 402f)).dp, modifier = Modifier.voiidSharedLogo())

            Spacer(Modifier.weight(1f))

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .graphicsLayer { alpha = contentAlpha; translationY = contentOffset },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Row(
                    // Left edge aligns with the centered 300dp Continue button (same inset),
                    // but the row extends wider so the agree text stays on ONE line like the design.
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            start = ((cfg.screenWidthDp - 300) / 2f).coerceAtLeast(16f).dp,
                            end = 16.dp,
                            bottom = 16.dp,
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    // Matches iOS: a plain toggle (no soft-press scale/dim — that press
                    // alpha is what made the box look like it "faded to white"), with the
                    // plum fill springing in like the iOS `withAnimation(.spring(0.25))`.
                    val boxShape = RoundedCornerShape(3.dp)
                    val fill by animateColorAsState(
                        targetValue = if (agreed) VoiidColor.primary else Color.Transparent,
                        animationSpec = spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow),
                        label = "termsCheckboxFill",
                    )
                    Box(
                        modifier = Modifier
                            .size(16.dp)
                            .clip(boxShape)
                            .background(fill)
                            .border(1.dp, VoiidColor.textSecondary, boxShape)
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                            ) { setAgreed(!agreed) },
                        contentAlignment = Alignment.Center,
                    ) {
                        // Fade the check in/out with the box's plum fill (animateColorAsState
                        // above drives the fill). Use alpha rather than AnimatedVisibility so
                        // the call stays in BoxScope, not the enclosing RowScope.
                        val checkAlpha by animateFloatAsState(
                            targetValue = if (agreed) 1f else 0f,
                            animationSpec = tween(150),
                            label = "termsCheckAlpha",
                        )
                        Icon(
                            Icons.Default.Check, null, tint = Color.White,
                            modifier = Modifier.size(10.dp).alpha(checkAlpha),
                        )
                    }
                    // FOUR Text nodes, not one AnnotatedString with link annotations.
                    // Compose's `LinkAnnotation` would keep this as a single wrapping
                    // paragraph and is the nicer API, but it is version-sensitive, and this
                    // line is on the path every single user walks on first launch: a plain
                    // `clickable` per span cannot break, and the design already constrains
                    // this to one line (see the padding comment on the Row).
                    //
                    // They live in their OWN Row because the outer one is `spacedBy(8.dp)`
                    // — which is the gap between the checkbox and the sentence, not between
                    // its words. Putting them in the outer Row would render "I accept the
                    // ⎵⎵ Terms & Conditions ⎵⎵ and ⎵⎵ Privacy Policy".
                    //
                    // Underlined as well as coloured. Colour alone is not an affordance —
                    // it fails for colour-blind users and it failed here for everyone, which
                    // is exactly how "Privacy Policy" looked like a link for months while
                    // being inert text.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("I accept the ", style = VoiidFont.rounded(13), color = VoiidColor.textPrimary)
                        Text(
                            "Terms & Conditions",
                            style = VoiidFont.rounded(13, FontWeight.SemiBold),
                            color = VoiidColor.textPrimary,
                            textDecoration = TextDecoration.Underline,
                            modifier = Modifier.clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                            ) { haptics.tap(); openDocument = com.voiid.app.legal.LegalDocuments.terms },
                        )
                        Text(" and ", style = VoiidFont.rounded(13), color = VoiidColor.textPrimary)
                        Text(
                            "Privacy Policy",
                            style = VoiidFont.rounded(13, FontWeight.SemiBold),
                            color = VoiidColor.textPrimary,
                            textDecoration = TextDecoration.Underline,
                            modifier = Modifier.clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                            ) { haptics.tap(); openDocument = com.voiid.app.legal.LegalDocuments.privacy },
                        )
                    }
                }

                // iOS uses a plain Button here (no press scale/dim), with a tap haptic
                // only when enabled — mirror that exactly.
                Box(
                    modifier = Modifier
                        .width(300.dp)
                        .height(64.dp)
                        .alpha(if (agreed) 1f else 0.5f)
                        .clip(RoundedCornerShape(VoiidRadius.pill))
                        .background(VoiidColor.accent)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            enabled = agreed,
                        ) { haptics.tap(); onContinue() },
                    contentAlignment = Alignment.Center,
                ) {
                    Text("Continue", style = VoiidFont.rounded(18, FontWeight.Medium), color = VoiidColor.textPrimary)
                }

                TextButton(onClick = onContinue, modifier = Modifier.padding(top = 16.dp)) {
                    Text("I already have an account", style = VoiidFont.rounded(14), color = VoiidColor.textPrimary)
                }

                Text(
                    "v1.0.0 (15)",
                    style = VoiidFont.rounded(12),
                    color = VoiidColor.textSecondary,
                    modifier = Modifier.padding(top = 16.dp, bottom = 24.dp),
                )
            }
        }
    }
}

// MARK: - Shared logo mark (Urbanist wordmark + soft halo, one baked image)

@Composable
fun LogoMark(size: Dp, modifier: Modifier = Modifier) {
    Image(
        painter = painterResource(R.drawable.voiid_logomark),
        contentDescription = "voiid",
        modifier = modifier.width(size),
        contentScale = ContentScale.FillWidth,
    )
}

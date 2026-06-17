package com.voiid.app.onboarding

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
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
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.R
import com.voiid.app.model.AppSession
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.delay

/** Splash → Terms → Phone → OTP → Signup → Create Profile → main app. Port of `OnboardingFlow.swift`. */

enum class OnbStep { TERMS, PHONE, OTP, SIGNUP, PROFILE }

@Composable
fun OnboardingFlow(session: AppSession) {
    var showSplash by remember { mutableStateOf(true) }
    var stack by remember { mutableStateOf(listOf(OnbStep.TERMS)) }
    var phone by remember { mutableStateOf("") }   // E.164, set by PhoneScreen, used by OtpScreen
    val current = stack.last()

    fun push(step: OnbStep) { stack = stack + step }
    fun pop() { if (stack.size > 1) stack = stack.dropLast(1) }

    BackHandler(enabled = stack.size > 1) { pop() }

    LaunchedEffect(Unit) {
        delay(1900)
        showSplash = false
    }

    Box(Modifier.fillMaxSize().background(VoiidColor.background)) {

        // Onboarding host (always composed under the splash so it cross-fades in).
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
                OnbStep.TERMS -> TermsScreen(onContinue = { push(OnbStep.PHONE) })
                OnbStep.PHONE -> PhoneScreen(onBack = ::pop, onContinue = { e164 -> phone = e164; push(OnbStep.OTP) })
                OnbStep.OTP -> OtpScreen(session = session, phoneE164 = phone, onBack = ::pop, onContinue = { push(OnbStep.SIGNUP) })
                OnbStep.SIGNUP -> SignupScreen(session = session, onBack = ::pop, onContinue = { push(OnbStep.PROFILE) })
                OnbStep.PROFILE -> CreateProfileScreen(session = session, onBack = ::pop, onFinish = { session.completeOnboarding() })
            }
        }

        // Splash overlays everything. As it leaves, the logo eases UPWARD toward the
        // Terms logo position while fading — a "connected" handoff closer to iOS's
        // matchedGeometry glide than a flat cross-fade. (Exact pixel-matching of the
        // shared element needs Compose SharedTransitionLayout + on-device tuning;
        // tracked as a follow-up — see ENGINEERING_HANDOFF.)
        AnimatedVisibility(
            visible = showSplash,
            enter = fadeIn(),
            exit = slideOutVertically(tween(550)) { -(it * 0.12f).toInt() } + fadeOut(tween(550)),
        ) {
            SplashScreen()
        }
    }
}

// MARK: - Splash (Urbanist logomark, embossed on #DFDFDF)

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

@Composable
fun TermsScreen(onContinue: () -> Unit) {
    val cfg = LocalConfiguration.current
    val haptics = LocalVoiidHaptics.current
    var agreed by remember { mutableStateOf(false) }
    var contentIn by remember { mutableStateOf(false) }
    val contentAlpha by animateFloatAsState(if (contentIn) 1f else 0f, tween(450), label = "termsAlpha")
    val contentOffset by animateFloatAsState(if (contentIn) 0f else 16f, tween(450), label = "termsOffset")
    LaunchedEffect(Unit) { delay(250); contentIn = true }

    Box(Modifier.fillMaxSize().background(VoiidColor.background)) {
        Column(
            modifier = Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(60.dp))
            LogoMark(size = (cfg.screenWidthDp * (300f / 402f)).dp)

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
                            ) { agreed = !agreed },
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
                    Text(
                        text = buildAnnotatedString {
                            append("I accept the ")
                            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append("Terms & Conditions") }
                            append(" and ")
                            withStyle(SpanStyle(color = VoiidColor.textSecondary)) { append("Privacy Policy") }
                        },
                        style = VoiidFont.rounded(13),
                        color = VoiidColor.textPrimary,
                    )
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

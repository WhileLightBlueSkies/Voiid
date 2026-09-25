package com.voiid.app.main.walkthrough

import android.content.Context
import android.provider.Settings
import android.view.HapticFeedbackConstants
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.GenericShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlin.math.roundToInt

import androidx.compose.foundation.layout.IntrinsicSize

object WalkthroughReplayBus {
    val events = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    fun request() { events.tryEmit(Unit) }
}

class AppWalkthroughUiState internal constructor(
    private val context: Context,
    private val accountID: String,
) {
    private val preferences = context.getSharedPreferences("app_walkthrough", Context.MODE_PRIVATE)
    private val prefix = "${accountID.ifBlank { "local" }}.v${AppWalkthroughPlan.VERSION}"
    private val completionKey = "$prefix.completed"
    private val progressKey = "$prefix.step"

    var currentIndex by mutableIntStateOf(
        if (AppWalkthroughPlan.presentationMode == WalkthroughPresentationMode.EVERY_APP_LAUNCH) 0
        else preferences.getInt(progressKey, 0).coerceIn(0, AppWalkthroughPlan.steps.lastIndex),
    )
        private set
    var presented by mutableStateOf(
        AppWalkthroughPlan.shouldPresent(preferences.getInt(completionKey, 0)),
    )
        private set

    val step: AppWalkthroughStep get() = AppWalkthroughPlan.steps[currentIndex]
    val isFirst: Boolean get() = currentIndex == 0
    val isLast: Boolean get() = currentIndex == AppWalkthroughPlan.steps.lastIndex

    fun advance() {
        if (isLast) {
            finish()
        } else {
            currentIndex += 1
            preferences.edit().putInt(progressKey, currentIndex).apply()
        }
    }

    fun back() {
        currentIndex = (currentIndex - 1).coerceAtLeast(0)
        preferences.edit().putInt(progressKey, currentIndex).apply()
    }

    fun skip() = finish()

    fun replay() {
        currentIndex = 0
        presented = true
    }

    private fun finish() {
        WalkthroughNavigationBus.setSettingsOpen(false)
        preferences.edit()
            .putInt(completionKey, AppWalkthroughPlan.VERSION)
            .remove(progressKey)
            .apply()
        presented = false
    }
}

val LocalWalkthroughState = androidx.compose.runtime.compositionLocalOf<AppWalkthroughUiState?> { null }

@Composable
fun rememberAppWalkthroughState(accountID: String?): AppWalkthroughUiState {
    val context = LocalContext.current.applicationContext
    val state = remember(accountID) { AppWalkthroughUiState(context, accountID ?: "local") }
    LaunchedEffect(state) {
        WalkthroughReplayBus.events.collect { state.replay() }
    }
    return state
}

@Composable
fun AppWalkthroughOverlay(state: AppWalkthroughUiState) {
    if (!state.presented) return
    val context = LocalContext.current
    val view = LocalView.current
    val density = LocalDensity.current
    val registry = LocalSpotlightRegistry.current
    val targetInfo = state.step.targetId?.let { registry.targets[it] }

    val reduceMotion = remember {
        Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }

    BackHandler(enabled = true) {
        view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        if (state.isFirst) state.skip() else state.back()
    }

    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
    val pulseScale by infiniteTransition.animateFloat(
        initialValue = 1.0f,
        targetValue = 1.25f,
        animationSpec = infiniteRepeatable(
            animation = tween(1300, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "pulseScale",
    )
    val pulseAlpha by infiniteTransition.animateFloat(
        initialValue = 0.85f,
        targetValue = 0.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(1300, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "pulseAlpha",
    )

    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .semantics {
                contentDescription = "App walkthrough. Step ${state.currentIndex + 1} of ${AppWalkthroughPlan.steps.size}."
            },
    ) {
        val screenWidthPx = constraints.maxWidth.toFloat()
        val screenHeightPx = constraints.maxHeight.toFloat()
        val primaryColor = VoiidColor.primary

        // 1. Scrim with cutout punched hole & animated pulse ring
        Canvas(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) {
                    view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                    state.advance()
                },
        ) {
            // Dimmed scrim background
            drawRect(color = Color.Black.copy(alpha = 0.72f))

            if (targetInfo != null) {
                val pad = with(density) { targetInfo.padding.toPx() }
                val left = targetInfo.bounds.left - pad
                val top = targetInfo.bounds.top - pad
                val right = targetInfo.bounds.right + pad
                val bottom = targetInfo.bounds.bottom + pad
                val width = right - left
                val height = bottom - top

                when (targetInfo.shape) {
                    SpotlightShapeType.CIRCLE -> {
                        val radius = (maxOf(width, height) / 2f)
                        val center = Offset(left + width / 2f, top + height / 2f)
                        // Clear hole
                        drawCircle(
                            color = Color.Transparent,
                            radius = radius,
                            center = center,
                            blendMode = BlendMode.Clear,
                        )
                        // Radiant pulse ring
                        drawCircle(
                            color = primaryColor.copy(alpha = pulseAlpha),
                            radius = radius * pulseScale,
                            center = center,
                            style = Stroke(width = with(density) { 2.5.dp.toPx() }),
                        )
                        // Sharp inner border ring
                        drawCircle(
                            color = primaryColor.copy(alpha = 0.6f),
                            radius = radius,
                            center = center,
                            style = Stroke(width = with(density) { 1.5.dp.toPx() }),
                        )
                    }
                    SpotlightShapeType.ROUNDED_RECT, SpotlightShapeType.CAPSULE -> {
                        val cornerPx = if (targetInfo.shape == SpotlightShapeType.CAPSULE) {
                            height / 2f
                        } else {
                            with(density) { targetInfo.cornerRadius.toPx() }
                        }
                        // Clear hole
                        drawRoundRect(
                            color = Color.Transparent,
                            topLeft = Offset(left, top),
                            size = Size(width, height),
                            cornerRadius = CornerRadius(cornerPx, cornerPx),
                            blendMode = BlendMode.Clear,
                        )
                        // Radiant pulse ring
                        val dw = width * (pulseScale - 1f) / 2f
                        val dh = height * (pulseScale - 1f) / 2f
                        drawRoundRect(
                            color = primaryColor.copy(alpha = pulseAlpha),
                            topLeft = Offset(left - dw, top - dh),
                            size = Size(width * pulseScale, height * pulseScale),
                            cornerRadius = CornerRadius(cornerPx * pulseScale, cornerPx * pulseScale),
                            style = Stroke(width = with(density) { 2.5.dp.toPx() }),
                        )
                        // Inner crisp border
                        drawRoundRect(
                            color = primaryColor.copy(alpha = 0.6f),
                            topLeft = Offset(left, top),
                            size = Size(width, height),
                            cornerRadius = CornerRadius(cornerPx, cornerPx),
                            style = Stroke(width = with(density) { 1.5.dp.toPx() }),
                        )
                    }
                }
            }
        }

        // 2. Skip action in top bar
        Text(
            "Skip",
            style = VoiidFont.rounded(15, FontWeight.SemiBold),
            color = Color.White.copy(alpha = 0.85f),
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(top = 12.dp, end = 20.dp)
                .softClickable {
                    view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                    state.skip()
                }
                .padding(8.dp),
        )

        // 3. Directional Speech Bubble Tooltip Card
        val cardModifier: Modifier
        val pointingUp: Boolean
        val arrowXOffsetPx: Float

        if (targetInfo != null) {
            val targetCenterY = targetInfo.bounds.center.y
            val targetCenterX = targetInfo.bounds.center.x
            pointingUp = targetCenterY < (screenHeightPx * 0.48f)

            arrowXOffsetPx = targetCenterX

            cardModifier = if (pointingUp) {
                // Target is in the upper area -> place card below it
                val topMargin = with(density) { (targetInfo.bounds.bottom + targetInfo.padding.toPx() + 14.dp.toPx()).toDp() }
                Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = topMargin)
            } else {
                // Target is in lower area -> place card above it
                val bottomMargin = with(density) { (screenHeightPx - targetInfo.bounds.top + targetInfo.padding.toPx() + 14.dp.toPx()).toDp() }
                Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = bottomMargin)
            }
        } else {
            // General welcome / completion card centered on screen
            pointingUp = false
            arrowXOffsetPx = screenWidthPx / 2f
            cardModifier = Modifier.align(Alignment.Center)
        }

        AnimatedContent(
            targetState = state.step,
            transitionSpec = {
                if (reduceMotion) {
                    fadeIn(tween(180)) togetherWith fadeOut(tween(180))
                } else {
                    (fadeIn(tween(220)) + scaleIn(tween(240), initialScale = 0.95f)) togetherWith
                        (fadeOut(tween(160)) + scaleOut(tween(180), targetScale = 0.95f))
                }.using(SizeTransform(clip = false))
            },
            label = "appWalkthroughStep",
            modifier = cardModifier,
        ) { step ->
            WalkthroughSpeechBubbleCard(
                step = step,
                state = state,
                hasArrow = targetInfo != null,
                pointingUp = pointingUp,
                arrowTargetX = arrowXOffsetPx,
                onAdvance = {
                    view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                    state.advance()
                },
                onBack = {
                    view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                    state.back()
                },
            )
        }
    }
}

@Composable
private fun WalkthroughSpeechBubbleCard(
    step: AppWalkthroughStep,
    state: AppWalkthroughUiState,
    hasArrow: Boolean,
    pointingUp: Boolean,
    arrowTargetX: Float,
    onAdvance: () -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val density = LocalDensity.current

    val imageResId = remember(step.graphicDrawableName) {
        step.graphicDrawableName?.let {
            context.resources.getIdentifier(it, "drawable", context.packageName)
        } ?: 0
    }

    val surfaceCardColor = VoiidColor.surfaceCard
    val arrowOffsetPx = arrowTargetX - with(density) { 18.dp.toPx() } - with(density) { 9.dp.toPx() }
    val minOffset = with(density) { 24.dp.toPx() }
    val screenWidth = context.resources.displayMetrics.widthPixels.toFloat()
    val maxOffset = screenWidth - with(density) { 36.dp.toPx() } - with(density) { 24.dp.toPx() } - with(density) { 18.dp.toPx() }
    val arrowOffsetDp = with(density) { arrowOffsetPx.coerceIn(minOffset, maxOf(minOffset, maxOffset)).toDp() }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 18.dp),
    ) {
        if (hasArrow && pointingUp) {
            Canvas(
                modifier = Modifier
                    .offset(x = arrowOffsetDp)
                    .size(width = 18.dp, height = 9.dp)
            ) {
                val path = androidx.compose.ui.graphics.Path().apply {
                    moveTo(0f, size.height)
                    lineTo(size.width / 2f, 0f)
                    lineTo(size.width, size.height)
                    close()
                }
                drawPath(path, color = surfaceCardColor)
            }
        }

        Column(
            Modifier
                .fillMaxWidth()
                .shadow(elevation = 28.dp, shape = RoundedCornerShape(26.dp), spotColor = Color.Black)
                .clip(RoundedCornerShape(26.dp))
                .background(surfaceCardColor)
                .border(1.dp, VoiidColor.divider.copy(alpha = 0.5f), RoundedCornerShape(26.dp)),
        ) {
            // Top: Full-width uncropped pastel photography banner
            if (imageResId != 0) {
                Image(
                    painter = painterResource(id = imageResId),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(152.dp)
                        .clip(RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp)),
                )
            }

            // Bottom: Text, progress indicator, and action buttons
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    step.eyebrow,
                    style = VoiidFont.rounded(11, FontWeight.Bold),
                    color = VoiidColor.primary,
                    letterSpacing = with(density) { 1.dp.toSp() },
                )
                Text(
                    step.title,
                    style = VoiidFont.rounded(20, FontWeight.Bold),
                    color = VoiidColor.textPrimary,
                    modifier = Modifier.semantics { heading() },
                )
                Text(
                    step.message,
                    style = VoiidFont.rounded(14),
                    color = VoiidColor.textSecondary,
                    lineHeight = with(density) { 20.dp.toSp() },
                )

                // Step Progress Track
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(top = 4.dp),
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                        AppWalkthroughPlan.steps.indices.forEach { index ->
                            Box(
                                Modifier
                                    .size(width = if (index == state.currentIndex) 20.dp else 6.dp, height = 6.dp)
                                    .clip(RoundedCornerShape(99.dp))
                                    .background(if (index == state.currentIndex) VoiidColor.primary else VoiidColor.divider),
                            )
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    Text(
                        "${state.currentIndex + 1} of ${AppWalkthroughPlan.steps.size}",
                        style = VoiidFont.rounded(12, FontWeight.SemiBold),
                        color = VoiidColor.textSecondary,
                    )
                }

                // Action Buttons Row
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.padding(top = 4.dp),
                ) {
                    if (!state.isFirst) {
                        WalkthroughButton("Back", primary = false, modifier = Modifier.weight(0.38f), onClick = onBack)
                    }
                    WalkthroughButton(
                        if (state.isLast) "Done" else "Next",  // iOS AppWalkthroughView
                        primary = true,
                        modifier = Modifier.weight(1f),
                        onClick = onAdvance,
                    )
                }
            }
        }

        if (hasArrow && !pointingUp) {
            Canvas(
                modifier = Modifier
                    .offset(x = arrowOffsetDp)
                    .size(width = 18.dp, height = 9.dp)
            ) {
                val path = androidx.compose.ui.graphics.Path().apply {
                    moveTo(0f, 0f)
                    lineTo(size.width / 2f, size.height)
                    lineTo(size.width, 0f)
                    close()
                }
                drawPath(path, color = surfaceCardColor)
            }
        }
    }
}

@Composable
private fun WalkthroughButton(
    label: String,
    primary: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .height(48.dp)
            .clip(RoundedCornerShape(99.dp))
            .background(if (primary) VoiidColor.primary else VoiidColor.surfaceRaised)
            .softClickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = VoiidFont.rounded(15, if (primary) FontWeight.Bold else FontWeight.SemiBold),
            color = if (primary) Color.White else VoiidColor.textPrimary,
        )
    }
}

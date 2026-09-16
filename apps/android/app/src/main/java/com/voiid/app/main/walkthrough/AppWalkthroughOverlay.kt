package com.voiid.app.main.walkthrough

import android.content.Context
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.flow.MutableSharedFlow

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
        preferences.getInt(progressKey, 0).coerceIn(0, AppWalkthroughPlan.steps.lastIndex),
    )
        private set
    var presented by mutableStateOf(
        preferences.getInt(completionKey, 0) < AppWalkthroughPlan.VERSION,
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
        preferences.edit()
            .putInt(completionKey, AppWalkthroughPlan.VERSION)
            .remove(progressKey)
            .apply()
        presented = false
    }
}

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
    val reduceMotion = remember {
        Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }

    BackHandler(enabled = true) {
        if (state.isFirst) state.skip() else state.back()
    }

    Box(
        Modifier.fillMaxSize()
            .background(Color.Black.copy(alpha = 0.62f))
            .semantics {
                contentDescription = "App walkthrough. Step ${state.currentIndex + 1} of ${AppWalkthroughPlan.steps.size}."
            },
    ) {
        Text(
            "Skip",
            style = VoiidFont.rounded(15, FontWeight.SemiBold),
            color = Color.White,
            modifier = Modifier.align(Alignment.TopEnd)
                .padding(top = 24.dp, end = 18.dp)
                .softClickable { state.skip() }
                .padding(12.dp),
        )

        AnimatedContent(
            targetState = state.step,
            transitionSpec = {
                if (reduceMotion) {
                    fadeIn(androidx.compose.animation.core.tween(180)) togetherWith
                        fadeOut(androidx.compose.animation.core.tween(180))
                } else {
                    (fadeIn(androidx.compose.animation.core.tween(180)) +
                        scaleIn(androidx.compose.animation.core.tween(200), initialScale = 0.97f)) togetherWith
                        (fadeOut(androidx.compose.animation.core.tween(140)) +
                            scaleOut(androidx.compose.animation.core.tween(160), targetScale = 0.97f))
                }.using(SizeTransform(clip = false))
            },
            label = "appWalkthroughStep",
            modifier = Modifier.align(Alignment.Center),
        ) { step ->
            WalkthroughCard(step, state)
        }
    }
}

@Composable
private fun WalkthroughCard(step: AppWalkthroughStep, state: AppWalkthroughUiState) {
    Column(
        Modifier.fillMaxWidth()
            .padding(horizontal = 20.dp)
            .clip(RoundedCornerShape(28.dp))
            .background(VoiidColor.surfaceCard)
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Text(
            step.eyebrow,
            style = VoiidFont.rounded(11, FontWeight.Bold),
            color = VoiidColor.accentInk,
        )
        Text(
            step.title,
            style = VoiidFont.rounded(25, FontWeight.Bold),
            color = VoiidColor.textPrimary,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            step.message,
            style = VoiidFont.rounded(16),
            color = VoiidColor.textSecondary,
        )

        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                AppWalkthroughPlan.steps.indices.forEach { index ->
                    Box(
                        Modifier.size(width = if (index == state.currentIndex) 22.dp else 6.dp, height = 6.dp)
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

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (!state.isFirst) {
                WalkthroughButton("Back", primary = false, modifier = Modifier.weight(0.42f)) { state.back() }
            }
            WalkthroughButton(
                if (state.isLast) "Done" else if (state.isFirst) "Start tour" else "Next",
                primary = true,
                modifier = Modifier.weight(1f),
            ) { state.advance() }
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
        modifier.height(50.dp)
            .clip(RoundedCornerShape(99.dp))
            .background(if (primary) VoiidColor.primary else VoiidColor.surfaceRaised)
            .softClickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = VoiidFont.rounded(16, if (primary) FontWeight.Bold else FontWeight.SemiBold),
            color = if (primary) Color.White else VoiidColor.textPrimary,
        )
    }
}

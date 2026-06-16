package com.voiid.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import com.voiid.app.main.MainScreen
import com.voiid.app.model.AIStore
import com.voiid.app.model.AppRoute
import com.voiid.app.model.AppSession
import com.voiid.app.model.ChatStore
import com.voiid.app.model.ClipsStore
import com.voiid.app.onboarding.OnboardingFlow
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.rememberVoiidHaptics
import com.voiid.app.ui.theme.VoiidTheme

/**
 * Single-activity Compose host. Mirrors the iOS `VoiidApp` + `ContentView`:
 * routes between the onboarding flow and the main tab app, owning the shared stores.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VoiidTheme {
                CompositionLocalProvider(LocalVoiidHaptics provides rememberVoiidHaptics()) {
                    VoiidRoot()
                }
            }
        }
    }
}

@Composable
private fun VoiidRoot() {
    val session: AppSession = viewModel()
    val chat: ChatStore = viewModel()
    val ai: AIStore = viewModel()
    val clips: ClipsStore = viewModel()

    Crossfade(targetState = session.route, animationSpec = tween(350), label = "rootRoute") { route ->
        when (route) {
            AppRoute.ONBOARDING -> OnboardingFlow(session)
            AppRoute.MAIN -> MainScreen(chat, ai, clips)
        }
    }
}

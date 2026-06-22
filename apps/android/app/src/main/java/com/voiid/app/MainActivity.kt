package com.voiid.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.voiid.app.net.ConfigService
import com.voiid.app.net.UpdateGate
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
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
    val context = LocalContext.current

    // Fetch remote config on launch (version negotiation + feature flags + force-update).
    LaunchedEffect(Unit) { ConfigService.fetch(context) }

    val updateRequired by UpdateGate.required.collectAsState()
    if (updateRequired) {
        UpdateRequiredScreen(storeUrl = UpdateGate.storeUrl)
        return
    }

    Crossfade(targetState = session.route, animationSpec = tween(350), label = "rootRoute") { route ->
        when (route) {
            AppRoute.ONBOARDING -> OnboardingFlow(session)
            AppRoute.MAIN -> MainScreen(chat, ai, clips)
        }
    }
}

@Composable
private fun UpdateRequiredScreen(storeUrl: String?) {
    val context = LocalContext.current
    Column(
        modifier = Modifier.fillMaxSize().background(VoiidColor.background).padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Update required", style = VoiidFont.rounded(22, FontWeight.Bold), color = VoiidColor.textPrimary)
        Spacer(Modifier.height(12.dp))
        Text(
            "A newer version of VOIID is needed to keep chatting securely. Please update to continue.",
            style = VoiidFont.rounded(15), color = VoiidColor.textSecondary, textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(24.dp))
        Button(onClick = {
            val url = storeUrl ?: "https://play.google.com/store/apps/details?id=com.voiid.app"
            context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url)))
        }) { Text("Update VOIID") }
    }
}

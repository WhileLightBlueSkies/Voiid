package com.voiid.app

import android.content.Intent
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
import com.voiid.app.net.DeepLinkRouter
import com.voiid.app.net.UpdateGate
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.main.CallPipController
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

    /** Owns Picture-in-Picture for connected video calls (see [CallPipController]). */
    private lateinit var pip: CallPipController

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        requestCallPermissions()
        pip = CallPipController(this).also {
            it.onRestoreInstanceState(savedInstanceState)
            it.attach(this)
        }
        // A notification tap (cold start) delivers the conversation id here.
        handleDeepLink(intent)
        ensureContactsAccount()
        // Load the Light/Dark/System choice BEFORE the first composition, or the app paints
        // one light frame and then snaps to dark.
        com.voiid.app.ui.theme.VoiidThemeStore.load(this)
        // Restore the saved chat-list layout before the first frame, so a user who chose
        // List does not see one frame of Grid on every launch.
        com.voiid.app.ui.theme.ChatLayoutPreference.load(this)
        com.voiid.app.ui.theme.VoiidThemeStore.applyToSystem(this)
        setContent {
            VoiidTheme {
                CompositionLocalProvider(LocalVoiidHaptics provides rememberVoiidHaptics()) {
                    VoiidRoot()
                }
            }
        }
    }

    // singleTop: a tap while the app is already running re-delivers here (not a new task).
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleDeepLink(intent)
    }

    /**
     * The user is leaving the app (Home / Recents). On a connected video call this is where
     * PiP is entered on Android 11 and below; on 12+ `setAutoEnterEnabled(true)` normally
     * beats us to it and this becomes a harmless no-op.
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (::pip.isInitialized) pip.onUserLeaveHint()
    }

    // PiP mode changes are observed through AndroidX's
    // `addOnPictureInPictureModeChangedListener` inside CallPipController, which plays better
    // with Compose than overriding onPictureInPictureModeChanged here.

    /** Keep the PiP aspect ratio stable if the activity is recreated while in PiP. */
    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        if (::pip.isInitialized) pip.onSaveInstanceState(outState)
    }

    override fun onStart() {
        super.onStart()
        com.voiid.app.net.CallManager.onHostForeground()
    }

    override fun onStop() {
        super.onStop()
        // In PiP the activity is still "visible" and must keep capturing; only a true
        // background transition may pause the camera.
        val inPip = ::pip.isInitialized && pip.isInPipNow()
        if (!inPip) com.voiid.app.net.CallManager.onHostBackground()
    }

    /**
     * Create the "Voiid" account that the contact-card rows hang off, once the user is
     * actually signed in.
     *
     * Idempotent and free after the first launch. Deliberately gated on being signed in: an
     * account appearing in Settings > Accounts before the user has even logged in would be
     * both confusing and useless (there would be no peers to write rows for).
     */
    private fun ensureContactsAccount() {
        if (com.voiid.app.net.TokenStore.get(this).jwt == null) return
        runCatching { com.voiid.app.contacts.VoiidAccountManager.ensureAccount(this) }
    }

    private fun handleDeepLink(intent: Intent?) {
        intent?.getStringExtra(DeepLinkRouter.EXTRA_CONVERSATION_ID)?.let { DeepLinkRouter.open(it) }
        intent?.getStringExtra(DeepLinkRouter.EXTRA_GROUP_CALL_CONVERSATION)?.let { conv ->
            DeepLinkRouter.joinGroupCall(conv, intent.getStringExtra(DeepLinkRouter.EXTRA_GROUP_CALL_KIND) == "video")
        }
    }

    /** Ensure mic/camera/notification permissions for 1:1 voice & video calls. */
    private fun requestCallPermissions() {
        val perms = mutableListOf(
            android.Manifest.permission.RECORD_AUDIO,
            android.Manifest.permission.CAMERA,
            // Contact-card integration: the "Voice call (Voiid)" / "Video call (Voiid)" rows
            // are RawContacts we write into the address book. Same CONTACTS group as the
            // already-requested READ_CONTACTS, so it normally rides along silently; a refusal
            // means no rows and nothing else. Re-asked here (as well as on the onboarding
            // permissions screen) so users who installed before this feature existed get the
            // chance to grant it. MANAGE_OWN_CALLS and FOREGROUND_SERVICE_PHONE_CALL are
            // install-time and need no code.
            android.Manifest.permission.WRITE_CONTACTS,
        )
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            perms.add(android.Manifest.permission.POST_NOTIFICATIONS)
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            // API 31+: AudioManager.setCommunicationDevice() needs BLUETOOTH_CONNECT to move
            // call audio onto a Bluetooth headset. Without it, a headset connected mid-call is
            // silently ignored and audio stays on the earpiece/speaker.
            perms.add(android.Manifest.permission.BLUETOOTH_CONNECT)
        }
        val missing = perms.filter {
            androidx.core.content.ContextCompat.checkSelfPermission(this, it) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) return
        val launcher = registerForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.RequestMultiplePermissions(),
        ) { /* calls re-check permission at start; nothing to do here */ }
        runCatching { launcher.launch(missing.toTypedArray()) }
    }
}

@Composable
private fun VoiidRoot() {
    val session: AppSession = viewModel()
    val chat: ChatStore = viewModel()
    val ai: AIStore = viewModel()
    val clips: ClipsStore = viewModel()
    val stories: com.voiid.app.model.StoriesStore = viewModel()
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
            AppRoute.MAIN -> MainScreen(chat, ai, clips, stories)
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

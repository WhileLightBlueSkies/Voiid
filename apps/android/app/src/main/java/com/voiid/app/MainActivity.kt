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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
        // Re-checked on every foreground, not just at launch: both the notification permission
        // and (on Android 14+) the full-screen-intent one are user-revocable from Settings, and
        // the banner that explains a phone which can't ring has to clear itself when they fix it.
        com.voiid.app.net.CallRingCapability.refresh(this)
        // MAP PRESENCE FOLLOWS THE APP, not the Map tab.
        //
        // These were called from MapTabView's DisposableEffect, which fires when you leave
        // the TAB — so opening the app on Chats never resumed sharing at all, and merely
        // switching tabs looked like backgrounding. `init` is safe to call repeatedly and is
        // what restores the share after a process kill.
        com.voiid.app.net.MapPresenceEngine.init(applicationContext)
        com.voiid.app.net.MapPresenceEngine.onForeground()
    }

    override fun onStop() {
        super.onStop()
        // In PiP the activity is still "visible" and must keep capturing; only a true
        // background transition may pause the camera.
        val inPip = ::pip.isInitialized && pip.isInPipNow()
        if (!inPip) com.voiid.app.net.CallManager.onHostBackground()
        // Step the Map down to the cheap background stream. NOT a stop — presence keeps
        // updating coarsely and can still relaunch a killed process.
        if (!inPip) com.voiid.app.net.MapPresenceEngine.onBackground()
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
        // A community invite link (https://voiid.app/c/<handle>?i=<token>) arrives as
        // ACTION_VIEW from the App Links filter, NOT as an extra — it comes from outside the
        // app, so there is nothing we put there to read back.
        //
        // The data is cleared as it is read, for the same reason the accept-call extras below
        // are removed: a singleTop Activity is handed the SAME Intent object again on every
        // later resume, and a lingering URI would re-open the join sheet every time the user
        // came back to the app.
        //
        // Parsing only; nothing is trusted. `parse` returns null for any URI that is not an
        // https voiid.app /c/ link with a well-formed handle, so a crafted intent from another
        // app produces nothing at all. Whether the community exists, whether the token is
        // live, and whether the user is already a member are all questions only the server
        // answers — see CommunityService.
        if (intent?.action == Intent.ACTION_VIEW) {
            val link = com.voiid.app.net.CommunityLink.parse(intent.data)
            if (link != null) {
                intent.data = null
                DeepLinkRouter.openCommunityInvite(link)
            }
        }
        intent?.getStringExtra(DeepLinkRouter.EXTRA_CONVERSATION_ID)?.let {
            // Consumed as it is read, for the same reason the accept extras below are: a
            // singleTop Activity is handed the SAME Intent object again on every later
            // resume, so a lingering extra re-fires its action every time the app is
            // foregrounded.
            intent.removeExtra(DeepLinkRouter.EXTRA_CONVERSATION_ID)
            DeepLinkRouter.open(it)
        }
        intent?.getStringExtra(DeepLinkRouter.EXTRA_GROUP_CALL_CONVERSATION)?.let { conv ->
            val video = intent.getStringExtra(DeepLinkRouter.EXTRA_GROUP_CALL_KIND) == "video"
            // MUST be consumed too. Without this, leaving a group call and then merely
            // switching back to the app re-joined it — the extra was still on the Intent and
            // fired again on every resume, which is indistinguishable from the app dragging
            // you back into a call you deliberately left.
            intent.removeExtra(DeepLinkRouter.EXTRA_GROUP_CALL_CONVERSATION)
            intent.removeExtra(DeepLinkRouter.EXTRA_GROUP_CALL_KIND)
            DeepLinkRouter.joinGroupCall(conv, video)
        }
        // Accept from the ring notification lands here, not in a BroadcastReceiver — see
        // CallForegroundService.acceptActivityIntent. The extra is removed as it is read: a
        // singleTop Activity is handed the same Intent object again on every later resume, and
        // a lingering call id would re-answer a call that is long over.
        val accepted = intent?.getStringExtra(DeepLinkRouter.EXTRA_ACCEPT_CALL_ID)
        val acceptedWaiting = intent?.getStringExtra(DeepLinkRouter.EXTRA_ACCEPT_WAITING_CALL_ID)
        if (accepted != null || acceptedWaiting != null) {
            intent?.removeExtra(DeepLinkRouter.EXTRA_ACCEPT_CALL_ID)
            intent?.removeExtra(DeepLinkRouter.EXTRA_ACCEPT_WAITING_CALL_ID)
            com.voiid.app.net.CallManager.init(applicationContext)
            if (accepted != null) DeepLinkRouter.answerCall(accepted)
            else DeepLinkRouter.answerCall(acceptedWaiting!!, waiting = true)
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

    // Answer a call the user accepted from the ring notification. Deliberately here rather
    // than in the Activity's intent handling: by the time this composes the window is up, so
    // the foreground service the answer starts is a legal foreground start.
    val pendingAnswer by DeepLinkRouter.pendingCallAnswer.collectAsState()
    LaunchedEffect(pendingAnswer) {
        val answer = pendingAnswer ?: return@LaunchedEffect
        DeepLinkRouter.consumeCallAnswer()
        val calls = com.voiid.app.net.CallManager
        if (answer.waiting) calls.acceptWaiting(answer.callId) else calls.accept(answer.callId)
        // The process may have been killed between the ring and the tap, leaving nothing to
        // answer — the ongoing ring notification would then sit there forever.
        com.voiid.app.net.CallForegroundService.cancelIncoming(context)
    }

    val updateRequired by UpdateGate.required.collectAsState()
    if (updateRequired) {
        UpdateRequiredScreen(storeUrl = UpdateGate.storeUrl)
        return
    }

    // A community invite link the user tapped. Held by DeepLinkRouter rather than consumed on
    // read, so a link opened on a fresh install SURVIVES onboarding: the sheet resolves against
    // the server with the caller's own session, and until there is a session there is nobody to
    // resolve it for. Waiting is the whole point — throwing the link away at that moment would
    // send a brand-new user to a blank Chats screen wondering what the link did.
    val communityInvite by DeepLinkRouter.pendingCommunityInvite.collectAsState()

    // DPDP consent. Two jobs here: flush the tick taken on the onboarding Terms screen once
    // there is an account to attach it to, and prompt accounts that predate consent capture
    // entirely (every account created before this shipped, because the endpoint had no
    // callers). Keyed on the ROUTE, not on Unit: the pending record is created several
    // screens into onboarding, so a launch-only effect would miss the very sign-up that
    // produced it and defer the post by a whole app session.
    LaunchedEffect(session.route) {
        if (session.route == AppRoute.MAIN) com.voiid.app.net.ConsentService.syncOnLaunch(context)
    }
    val needsConsent by com.voiid.app.net.ConsentService.needsBackfill.collectAsState()
    // "Not now" holds for this process only. Deliberately not persisted: a dismissal is not
    // an answer, and a permanent "never ask again" would leave the account being processed
    // with nothing recorded at all.
    var consentDeferred by remember { mutableStateOf(false) }

    Crossfade(targetState = session.route, animationSpec = tween(350), label = "rootRoute") { route ->
        when (route) {
            AppRoute.ONBOARDING -> OnboardingFlow(session)
            AppRoute.MAIN -> MainScreen(chat, ai, clips, stories)
        }
    }

    if (session.route == AppRoute.MAIN && needsConsent && !consentDeferred) {
        androidx.compose.ui.window.Dialog(
            onDismissRequest = { consentDeferred = true },
            properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        ) {
            com.voiid.app.main.ConsentPromptScreen(
                onDefer = { consentDeferred = true },
                onAccepted = { consentDeferred = false },
            )
        }
    }

    // Presented HERE, above the route crossfade, rather than from MainScreen's tab body: a link
    // can land while any tab is showing, and the sheet is not the Communities tab's content —
    // it is a modal about one community. Keeping it out of RootTabView also keeps this feature
    // from having an opinion about how that tab is eventually built.
    val invite = communityInvite
    if (invite != null && session.route == AppRoute.MAIN) {
        com.voiid.app.main.CommunityJoinSheet(
            link = invite,
            onDismiss = { DeepLinkRouter.consumeCommunityInvite() },
        )
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

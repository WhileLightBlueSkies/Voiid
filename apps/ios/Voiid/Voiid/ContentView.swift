//
//  ContentView.swift
//  Voiid
//
//  Root view — routes between the onboarding flow and the main tab app.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var session = AppSession()
    @StateObject private var chat = ChatStore()
    @StateObject private var ai = AIStore()
    @ObservedObject private var call = CallService.shared
    /// Drives the app-wide Light / Dark / System choice (Settings → Appearance).
    @ObservedObject private var theme = ThemePreference.shared
    /// DPDP consent. Two jobs on this screen: flush the tick taken during onboarding once
    /// there is an account to attach it to, and prompt the accounts that predate consent
    /// capture entirely. See ConsentService for why the tick cannot be posted where it is
    /// taken.
    @ObservedObject private var consent = ConsentService.shared
    /// "Not now" on the backfill prompt. Deliberately NOT persisted: the prompt returns on
    /// the next launch, because a dismissal is not an answer and a permanent "never ask
    /// again" would leave the account being processed with nothing recorded at all.
    @State private var consentDeferred = false
    /// Set when the user taps the PiP window (or the in-app floating window) to
    /// come back to a call whose screen is no longer presented.
    @State private var restoreCallUIRequested = false
    /// A community invite link the user tapped (see `CommunityLink`).
    @ObservedObject private var communityLinks = CommunityLinkRouter.shared

    var body: some View {
        Group {
            switch session.route {
            case .onboarding:
                OnboardingFlow()
            case .main:
                RootTabView()
            }
        }
        .environmentObject(session)
        .environmentObject(chat)
        .environmentObject(ai)
        .tint(VoiidColor.primary)
        // The app is no longer pinned to light: every VoiidColor token resolves per theme
        // (Peacock), so this follows the user's Light / Dark / System choice. `.system`
        // yields nil, which SwiftUI reads as "inherit from the OS".
        .preferredColorScheme(theme.mode.colorScheme)
        // Push the SAVED preference into the UIKit window on launch. Without this the very
        // first frame resolves VoiidColor tokens against the OS style, so a user who chose
        // Dark on a Light phone would see one light frame before it corrected itself.
        .onAppear { theme.applyToWindows() }
        // Runs on every transition into the main app, not once per process: the pending
        // onboarding record is created several screens INTO onboarding, so a task keyed to
        // launch alone would miss the very sign-up that produced it and defer the post by a
        // whole app session.
        .task(id: session.route) {
            guard session.route == .main else { return }
            await consent.syncOnLaunch()
        }
        .sheet(isPresented: Binding(
            get: { session.route == .main && consent.needsBackfill && !consentDeferred },
            set: { if !$0 { consentDeferred = true } })) {
            ConsentPromptView(
                onDefer: { consentDeferred = true },
                onAccepted: { consentDeferred = false })
        }
        // Global incoming-call surface: an inbound 1:1 call (offer received over the
        // socket) presents the call screen over whatever is on screen.
        .fullScreenCover(isPresented: incomingCallPresented) {
            if let c = call.active {
                CallScreen(request: CallRequest(
                    title: c.title, isGroup: false, members: [], photoName: nil,
                    kind: c.isVideo ? .video : .voice, peerUserId: c.peerUserId))
            }
        }
        // A tapped community invite link. Presented HERE, above the onboarding/main
        // switch, rather than from RootTabView: a link can land while any tab is showing,
        // and the sheet is not the Communities tab's content — it is a modal about one
        // community. Keeping it out of RootTabView also keeps this feature from having an
        // opinion about how that tab is eventually built.
        //
        // Gated on being past onboarding because the card is resolved with the caller's own
        // session and there is nobody to resolve it for until then. The router HOLDS the
        // link rather than dropping it, so an invite tapped on a fresh install opens once
        // the user signs in — which is the whole point of an invite link on a fresh install.
        .sheet(item: communityInvite) { link in
            CommunityJoinSheet(link: link)
        }
        // Tapping the PiP window asks the app to bring the call UI back. Usually
        // the call screen is still presented underneath (backgrounding does not
        // dismiss it) and this is a no-op; it matters when the call screen was
        // dismissed while the call carried on.
        .onReceive(NotificationCenter.default.publisher(for: .voiidRestoreCallUI)) { _ in
            guard call.active != nil, !call.callUIVisible else { return }
            call.restoreCallUI()
            restoreCallUIRequested = true
        }
    }

    /// The pending invite link, as a binding `.sheet(item:)` can drive.
    ///
    /// Reading nil while onboarding is what makes the link WAIT rather than be lost: the
    /// router still holds it, so the moment `session.route` flips to `.main` this publishes a
    /// value and the sheet appears. Dismissal is the only thing that clears the router — a
    /// sheet the system dismissed for its own reasons (another sheet, a backgrounded scene)
    /// would otherwise silently eat the invite.
    private var communityInvite: Binding<CommunityLink?> {
        Binding(
            get: { session.route == .main ? communityLinks.pending : nil },
            set: { if $0 == nil { communityLinks.consume() } }
        )
    }

    /// Present the global call surface for an INCOMING call (an outgoing call is
    /// already presented from the chat detail screen), or when a PiP restore asked
    /// for the call UI back and nothing else is showing it.
    private var incomingCallPresented: Binding<Bool> {
        Binding(
            get: {
                guard let active = call.active, active.state != .ended,
                      !call.callUIMinimized else { return false }
                return !active.isOutgoing || restoreCallUIRequested
            },
            set: { presented in
                if !presented { restoreCallUIRequested = false }
            }
        )
    }
}

#Preview {
    ContentView()
}

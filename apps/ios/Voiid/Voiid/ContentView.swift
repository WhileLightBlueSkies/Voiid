//
//  ContentView.swift
//  Voiid
//
//  Root view — routes between the onboarding flow and the main tab app.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var ticketLinks = EventTicketLinkRouter.shared
    @ObservedObject private var notificationRouter = NotificationMessageRouter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = AppSession()
    @StateObject private var chat = ChatStore()
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
    /// A personal profile link — a scanned QR, or voiid.app/u/<username> opened from
    /// anywhere (see `ProfileLink`).
    @ObservedObject private var profileLinks = ProfileLinkRouter.shared

    /// APP-WIDE, not per-screen.
    ///
    /// This used to be a @StateObject inside ClipsFeedView, which made it unreachable from
    /// Communities and Games — so when the server started gating those too, there was no
    /// engine there to raise the setup sheet. Owning it here means one profile, one gate, and
    /// one sheet no matter which surface asked for it.
    @StateObject private var social = SocialEngine()

    var body: some View {
        Group {
            switch session.route {
            case .onboarding:
                OnboardingFlow()
            case .main:
                RootTabView()
            }
        }
        .environmentObject(social)
        // LOADED ONCE, AT THE ROOT, for the same reason the engine lives here.
        //
        // `ensureMeLoaded()` was called only from ClipsFeedView, so `social.me` stayed nil
        // until somebody opened the Clips tab. Every surface that reads it — the profile
        // button now in the Games and Communities headers — therefore rendered nothing on a
        // fresh launch, and looked broken rather than empty.
        //
        // Guarded by the route: there is no profile to fetch during onboarding, and asking
        // for one before a session exists is a 401 the engine would log for no reason.
        .task(id: session.route) {
            guard session.route == .main else { return }
            await social.ensureMeLoaded()
        }
        // MOUNTED ONCE, at the root. Any surface that hits `profile_required` sets
        // `social.showSetup`, and the sheet appears over whatever the person was doing —
        // rather than each screen carrying its own copy that only works where it was added.
        .sheet(isPresented: $social.showSetup) {
            SocialSetupSheet { profile in
                social.profileCreated(profile)
            }
            .environmentObject(social)
        }
        .overlay(alignment: .top) {
            if session.route == .main, let banner = notificationRouter.banner {
                VStack(spacing: 8) {
                    MessageNotificationCapsule(banner: banner, onOpen: {
                        Haptics.tap()
                        notificationRouter.openBanner(banner)
                    }, onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) { notificationRouter.dismissBanner(banner.id) }
                    })
                    if notificationRouter.banners.count > 1 {
                        Text("+\(notificationRouter.banners.count - 1) more notifications")
                            .font(.caption2).foregroundStyle(VoiidColor.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                .padding(.horizontal, 24)
                .transition(reduceMotion ? .opacity : .offset(y: -22).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .top)))
                .task(id: banner.id) {
                    do { try await Task.sleep(for: .seconds(6)) } catch { return }
                    withAnimation(.easeOut(duration: 0.15)) { notificationRouter.dismissBanner(banner.id) }
                }
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.25, bounce: 0.1), value: notificationRouter.banner != nil)
        .onReceive(NotificationCenter.default.publisher(for: .voiidDidSignOut)) { _ in
            notificationRouter.resetForSignOut()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { notificationRouter.dismissBanner() }
        }
        .onChange(of: session.route) { _, route in
            if route != .main { notificationRouter.dismissBanner() }
        }
        .environmentObject(session)
        .environmentObject(chat)
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
        // CallKit owns incoming ringing. Present our call controls only after the
        // user answers, without covering the current screen with a second ring UI.
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
        .sheet(item: Binding(get: { session.route == .main ? ticketLinks.pending : nil }, set: { ticketLinks.pending = $0 })) { destination in
            LinkedEventTicketView(ticketId: destination.id)
        }
        .sheet(item: communityInvite) { link in
            CommunityJoinSheet(link: link)
        }
        // A scanned or tapped profile link lands in the SAME flow a typed handle uses:
        // look the person up, enter their Contact PIN, send a request they must accept.
        // The link supplies the handle and nothing else — see `ProfileLink`.
        .sheet(item: profileInvite) { link in
            FindByUsernameView(
                prefilledHandle: link.username,
                onOpen: { _, _ in
                    // Dismiss and let the chat list surface it. A request is PENDING until
                    // the other side accepts, so pushing straight into a conversation would
                    // present an empty thread as though it were live — and `ChatStore.open`
                    // needs a VConversation the list has not fetched yet.
                    profileLinks.consume()
                    Task { await chat.loadConversations() }
                }
            )
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

    /// Gated on `.main` for the same reason as the community binding: a link can arrive
    /// during a cold launch, before there is a session to look a handle up with. It waits
    /// in the router until there is.
    private var profileInvite: Binding<ProfileLink?> {
        Binding(
            get: { session.route == .main ? profileLinks.pending : nil },
            set: { if $0 == nil { profileLinks.consume() } }
        )
    }

    /// Present the global call surface for an INCOMING call (an outgoing call is
    /// already presented from the chat detail screen), or when a PiP restore asked
    /// for the call UI back and nothing else is showing it.
    private var incomingCallPresented: Binding<Bool> {
        Binding(
            get: {
                guard let active = call.active, active.state != .ended,
                      active.state != .incomingRinging,
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


private struct MessageNotificationCapsule: View {
    let banner: NotificationMessageRouter.Banner
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Circle().fill(VoiidColor.primary).frame(width: 34, height: 34)
                    .overlay(Text(banner.title.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined())
                        .font(.caption.bold()).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text(banner.title).font(.system(.subheadline, design: .rounded, weight: .semibold)).lineLimit(1)
                    Text(banner.count > 1 ? "\(banner.count) messages · \(banner.body)" : banner.body)
                        .font(.system(.caption, design: .rounded)).foregroundStyle(VoiidColor.textSecondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(VoiidColor.textPrimary)
            .padding(13).padding(.trailing, 34)
            .modifier(MessageCapsuleGlass(reduceTransparency: reduceTransparency, dark: scheme == .dark))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("notification.openMessage")
        .accessibilityHint("Opens this message in its chat")
        .overlay(alignment: .trailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Dismiss notification")
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.12), radius: 18, y: 7)
    }
}

private struct MessageCapsuleGlass: ViewModifier {
    let reduceTransparency: Bool
    let dark: Bool
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(VoiidColor.surfaceCard, in: Capsule())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(dark ? .black.opacity(0.22) : .white.opacity(0.18)).interactive(), in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

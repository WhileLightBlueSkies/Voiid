//
//  VoiidApp.swift
//  Voiid
//
//  Created by Bask Creative on 15/06/26.
//

import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseMessaging
import UIKit
import UserNotifications
import Combine

/// Retains notification destinations across cold launch, sign-in, and tab changes.
@MainActor
final class NotificationMessageRouter: ObservableObject {
    struct Destination: Equatable, Identifiable {
        let id = UUID()
        let conversationId: String
        let messageId: String?
    }
    static let shared = NotificationMessageRouter()
    @Published private(set) var pendingConversation: Destination?
    @Published private(set) var pendingMessage: Destination?
    struct Banner: Identifiable {
        let id = UUID()
        let conversationId: String
        let messageId: String?
        let title: String
        let body: String
        var count: Int = 1
        var communityHandle: String? = nil
    }
    @Published private(set) var banners: [Banner] = []
    var banner: Banner? { banners.first }
    private var recentBannerIDs: [String] = []
    func showBanner(conversationId: String, messageId: String?, title: String, body: String) {
        guard !conversationId.isEmpty, !MuteStore.isMuted(conversationId),
              ChatPresence.openConversationId != conversationId else { return }
        if let messageId {
            let key = conversationId + ":" + messageId
            guard !recentBannerIDs.contains(key) else { return }
            recentBannerIDs.append(key)
            if recentBannerIDs.count > 128 { recentBannerIDs.removeFirst() }
        }
        let count = (banners.first { $0.conversationId == conversationId }?.count ?? 0) + 1
        var next = banners.filter { $0.conversationId != conversationId }
        next.insert(Banner(conversationId: conversationId, messageId: messageId,
                           title: title.isEmpty ? "Voiid" : title, body: body.isEmpty ? "New message" : body,
                           count: count), at: 0)
        banners = Array(next.prefix(3))
    }
    func showCommunityApproval(_ handle: String, isRequest: Bool = false, isUpdate: Bool = false) {
        let item = Banner(conversationId: "", messageId: nil, title: isUpdate ? "New community update" : isRequest ? "New community join request" : "Community request approved", body: "Tap to open the community", communityHandle: handle)
        banners = Array(([item] + banners.filter { $0.communityHandle != handle }).prefix(3))
    }
    func openBanner(_ banner: Banner) {
        if let handle = banner.communityHandle {
            banners.removeAll { $0.id == banner.id }
            CommunityLinkRouter.shared.handle(URL(string: "https://voiid.app/c/\(handle)"))
        } else { open(conversationId: banner.conversationId, messageId: banner.messageId) }
    }
    func resetForSignOut() {
        banners = []
        pendingConversation = nil
        pendingMessage = nil
        recentBannerIDs.removeAll()
    }
    func dismissBanner(_ id: UUID? = nil) {
        guard let id else { banners = []; return }
        guard banner?.id == id else { return }
        banners = Array(banners.dropFirst()).filter {
            !MuteStore.isMuted($0.conversationId) && ChatPresence.openConversationId != $0.conversationId
        }
    }
    func open(conversationId: String, messageId: String?) {
        guard !conversationId.isEmpty else { return }
        banners.removeAll { $0.conversationId == conversationId }
        let destination = Destination(conversationId: conversationId, messageId: messageId)
        pendingMessage = messageId?.isEmpty == false ? destination : nil
        pendingConversation = destination
    }
    func navigationFailed(_ destination: Destination) {
        guard pendingConversation == destination else { return }
        banners.removeAll { $0.conversationId == destination.conversationId }
        banners.insert(Banner(conversationId: destination.conversationId, messageId: destination.messageId,
                        title: "Couldn't open chat", body: "Tap to try again when you're connected."), at: 0)
        banners = Array(banners.prefix(3))
    }
    func consumeConversation(_ destination: Destination) {
        if pendingConversation == destination { pendingConversation = nil }
    }
    func consumeMessage(_ destination: Destination) {
        if pendingMessage == destination { pendingMessage = nil }
    }
}

/// AppDelegate forwards APNs + URL callbacks to Firebase Auth AND handles message
/// notifications: it becomes the UNUserNotificationCenter delegate so a tapped
/// notification deep-links to its conversation, and foreground pushes still present
/// (and are decrypted by the NSE). Phone Auth (OTP) also needs the APNs/URL wiring:
/// it verifies the app via silent push and falls back to a reCAPTCHA web flow.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        // A SAFETY NET, NOT THE ASK. Onboarding's PermissionsScreen is where this app
        // primes notifications, alongside contacts/camera/mic/photos — that is the right
        // place and it stays the only place a first-run user is prompted.
        //
        // This covers the installs that never went through it: an upgrade from a build
        // that predates the screen, and an account signed in before the prompt existed.
        // Those devices are stuck with authorizationStatus == .notDetermined forever, so
        // iOS issues NO alert token, didRegisterForRemoteNotificationsWithDeviceToken is
        // never called, and devices.push_token stays NULL for the life of the install —
        // which is the state every iOS row in the database is in right now, with
        // voip_token populated beside it. That asymmetry is the diagnosis: PushKit tokens
        // need no user authorization, alert tokens do. Calls rang; messages never woke
        // the app.
        //
        // ensureAuthorization prompts ONLY when the status is still .notDetermined, so a
        // user who already answered — either way — is never asked again by this.
        //
        // On didBecomeActive rather than inline: it also guards on the app being frontmost
        // (prompting from a background wake burns the one-shot dialog unseen), and the
        // state during didFinishLaunching is still .inactive, so an inline call would hit
        // that guard and silently do nothing.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MissedCallNotifier.ensureAuthorization()
        }
        // Register for remote notifications so the server can send the NSE-triggering
        // message push (and Firebase Auth's silent verification push).
        application.registerForRemoteNotifications()
        // Separate, high-priority push channel for incoming calls: PushKit VoIP.
        // Alert pushes are best-effort and get dropped for killed/backgrounded apps,
        // which loses calls; a VoIP push wakes us and we ring CallKit immediately.
        VoIPPushManager.shared.start()

        // A LOCATION LAUNCH IS HEADLESS. When significant-change relaunches a terminated app
        // there is no window and no view, so nothing in `onAppear` runs — the engine has to
        // be constructed HERE or the wake does nothing and the user's pin stays frozen.
        //
        // `launchOptions[.location]` tells us this specific launch was caused by a location
        // event, but the engine is touched unconditionally: it is also correct on a normal
        // launch (it prunes the stale trail and resumes the stream if the user is visible),
        // and gating it would mean two paths that can drift.
        _ = MapPresenceEngine.shared

        return true
    }

    /// Actions on a missed-call banner. Registered here (not lazily) because iOS
    /// resolves a notification's `categoryIdentifier` against whatever was registered
    /// when the notification is DELIVERED — and a missed-call notification is
    /// routinely delivered by the system while the app is not running.
    private func registerNotificationCategories() {
        let callBack = UNNotificationAction(identifier: MissedCallNotifier.actionCallBack,
                                            title: "Call back", options: [.foreground])
        let message = UNNotificationAction(identifier: MissedCallNotifier.actionMessage,
                                           title: "Message", options: [.foreground])
        let missedCall = UNNotificationCategory(identifier: MissedCallNotifier.categoryId,
                                                actions: [callBack, message],
                                                intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([missedCall])
    }

    // MARK: - Message notifications (UNUserNotificationCenterDelegate)

    /// Notification tapped → deep-link to its conversation. Reads the NON-SECRET
    /// `conversation_id` routing key the server/NSE attached (never any content).
    ///
    /// A missed-call banner carries the same key, so a plain tap opens the caller's
    /// chat with no extra navigation code; only its "Call back" action needs its own
    /// branch (there is no calls/recents screen to send anyone to).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { completionHandler(); return }
        let userInfo = response.notification.request.content.userInfo
        if ["community_approved", "community_request", "community_update"].contains(userInfo["type"] as? String ?? ""),
           let handle = userInfo["community_handle"] as? String,
           handle.range(of: "^[a-z0-9_]{3,64}$", options: .regularExpression) != nil {
            Task { @MainActor in CommunityLinkRouter.shared.handle(URL(string: "https://voiid.app/c/\(handle)")) }
            completionHandler(); return
        }

        if response.actionIdentifier == MissedCallNotifier.actionCallBack,
           userInfo["type"] as? String == MissedCallNotifier.typeValue,
           let callerId = userInfo["caller_id"] as? String, !callerId.isEmpty {
            CallService.shared.startCall(
                peerUserId: callerId,
                title: UserDirectory.shared.displayName(callerId),
                isVideo: (userInfo["call_kind"] as? String) == "video",
                conversationId: userInfo["conversation_id"] as? String
            )
            completionHandler()
            return
        }
        // Tapped a "join group call" notification → join the LiveKit room. A group call has no
        // single callee, so it's a joinable invite (not a CallKit 1:1 report).
        if userInfo["type"] as? String == "group_call",
           let conversationId = userInfo["conversation_id"] as? String {
            let isVideo = (userInfo["call_kind"] as? String) == "video"
            Task { await GroupCallService.shared.join(conversationId: conversationId,
                                                      title: "Group call", isVideo: isVideo) }
            completionHandler()
            return
        }
        if let conversationId = userInfo["conversation_id"] as? String {
            let messageId = userInfo["message_id"] as? String
            Task { @MainActor in
                NotificationMessageRouter.shared.open(conversationId: conversationId, messageId: messageId)
            }
        }
        completionHandler()
    }

    /// Foreground arrival.
    ///
    /// Two things are suppressed here, for the same reason and by the same rule: a banner
    /// the user cannot act on is noise, and it covers the thing it is announcing.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        let info = content.userInfo
        let kind = info["type"] as? String
        if kind == "community_approved" || kind == "community_request" || kind == "community_update" {
            NotificationCenter.default.post(name: Notification.Name("communityMembershipChanged"), object: nil, userInfo: info)
            if let handle = info["community_handle"] as? String,
               handle.range(of: "^[a-z0-9_]{3,64}$", options: .regularExpression) != nil {
                Task { @MainActor in
                    NotificationMessageRouter.shared.showCommunityApproval(handle, isRequest: kind == "community_request", isUpdate: kind == "community_update")
                }
            }
            completionHandler([]); return
        }

        // Calls keep their established CallKit/system notification behavior.
        if kind == "call" || kind == "group_call" || kind == MissedCallNotifier.typeValue {
            completionHandler([.banner, .sound, .list])
            return
        }
        completionHandler([])
        guard let conversationId = info["conversation_id"] as? String else { return }
        Task { @MainActor in
            guard UIApplication.shared.applicationState == .active else { return }
            NotificationMessageRouter.shared.showBanner(conversationId: conversationId,
                messageId: info["message_id"] as? String, title: content.title, body: content.body)
        }
    }

    // APNs token -> Firebase Auth (used for silent-push app verification) AND the
    // backend. Firebase keeps the token to itself; without the second call
    // `devices.push_token` stays NULL and every alert/wake push aimed at this device —
    // messages, the call-ring fallback, group-call invites — has nowhere to go.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
        // Handed over EXPLICITLY because FirebaseAppDelegateProxyEnabled is false (see
        // Info.plist). With the proxy on, Firebase swizzled this method and set both of
        // these itself — while silently preventing our own registerPushToken below from
        // ever running, which is what kept devices.push_token NULL. With the proxy off
        // the swizzle is gone, so FCM must be given the token here or it would lose the
        // APNs binding that FCM delivery depends on.
        Messaging.messaging().apnsToken = deviceToken
        E2EManager.shared.registerPushToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Silent otherwise: no token means no pushes at all, and the only symptom is
        // an app that never rings.
        NSLog("[VOIID] APNs registration failed: \(error.localizedDescription)")
    }

    // Let Firebase Auth consume its verification push before the app sees it.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification notification: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if Auth.auth().canHandleNotification(notification) {
            completionHandler(.noData)
            return
        }
        completionHandler(.newData)
    }

    // reCAPTCHA fallback redirects back via the REVERSED_CLIENT_ID URL scheme.
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        return Auth.auth().canHandle(url)
    }
}

@main
struct VoiidApp: App {
    // Routes UIApplicationDelegate callbacks (APNs / URL) into Firebase Auth.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .voiidForceUpdateGate()   // /config on launch + blocking update screen on 426
                // Inherited by every tab, navigation destination, and presented sheet.
                .softTopEdgeEffect()
                // Contact linking, inbound half: tapping a Voiid entry in the phone
                // app's Recents, or the Voiid row inside a contact card, resumes the
                // app with an INStartCallIntent naming the person to call.
                .onContinueUserActivity("INStartCallIntent") { activity in
                    CallIntentRouter.startCall(from: activity)
                }
                // Legacy activity types, for call-back entries donated by older builds.
                .onContinueUserActivity("INStartAudioCallIntent") { activity in
                    CallIntentRouter.startCall(from: activity)
                }
                .onContinueUserActivity("INStartVideoCallIntent") { activity in
                    CallIntentRouter.startCall(from: activity, forceVideo: true)
                }
                // ===== Universal Links ==========================================
                // A community invite link — https://voiid.app/c/<handle>?i=<token>.
                //
                // NSUserActivityTypeBrowsingWeb is the ONLY inbound path, and there is
                // deliberately no `voiid://` custom-scheme twin: any app on the device can
                // claim a custom scheme, and iOS would then hand a LIVE INVITE TOKEN to
                // whichever app registered it. A universal link is bound to a domain we
                // control by the associated-domains entitlement plus the AASA file at
                // https://voiid.app/.well-known/apple-app-site-association (see
                // infrastructure/deployment/well-known/). Until that file is served, the
                // link opens Safari instead — the feature degrades, it does not break.
                //
                // Handled HERE rather than in AppDelegate: SwiftUI's scene owns
                // `application(_:continue:restorationHandler:)` in this lifecycle, and
                // implementing it on the delegate would silently stop the Siri call-intent
                // handlers directly above from firing. It covers the cold-launch case too —
                // the activity is replayed into the scene once the window exists.
                //
                // The router only PARKS the parsed link. Nothing is trusted, nothing is
                // decoded, and no request is made until a view with a signed-in session
                // asks the server what this handle actually is.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Both routers see the URL; each ignores what is not its own shape, so
                    // order does not matter and neither can swallow the other's link.
                    EventTicketLinkRouter.shared.handle(activity.webpageURL)
                    CommunityLinkRouter.shared.handle(activity.webpageURL)
                    ProfileLinkRouter.shared.handle(activity.webpageURL)
                }
        }
    }
}

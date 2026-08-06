//
//  VoiidApp.swift
//  Voiid
//
//  Created by Bask Creative on 15/06/26.
//

import SwiftUI
import FirebaseCore
import FirebaseAuth
import UIKit
import UserNotifications

extension Notification.Name {
    /// Posted when the user taps a message notification. `object` is the
    /// `conversation_id` to deep-link to. ChatsHomeView observes this.
    static let voiidOpenConversation = Notification.Name("voiidOpenConversation")
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
        let userInfo = response.notification.request.content.userInfo
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
            NotificationCenter.default.post(name: .voiidOpenConversation, object: conversationId)
        }
        completionHandler()
    }

    /// Foreground arrival: still show the banner/sound (the NSE already decrypted +
    /// rewrote the content), so the user sees the real message even in-app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
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
                    CommunityLinkRouter.shared.handle(activity.webpageURL)
                }
        }
    }
}

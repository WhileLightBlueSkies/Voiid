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
        // Register for remote notifications so the server can send the NSE-triggering
        // message push (and Firebase Auth's silent verification push).
        application.registerForRemoteNotifications()
        // Separate, high-priority push channel for incoming calls: PushKit VoIP.
        // Alert pushes are best-effort and get dropped for killed/backgrounded apps,
        // which loses calls; a VoIP push wakes us and we ring CallKit immediately.
        VoIPPushManager.shared.start()
        return true
    }

    // MARK: - Message notifications (UNUserNotificationCenterDelegate)

    /// Notification tapped → deep-link to its conversation. Reads the NON-SECRET
    /// `conversation_id` routing key the server/NSE attached (never any content).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
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

    // APNs token -> Firebase Auth (used for silent-push app verification).
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
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
        }
    }
}

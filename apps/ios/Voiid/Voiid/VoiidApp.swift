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

/// AppDelegate exists solely to forward APNs + URL callbacks to Firebase Auth.
/// Phone Auth (OTP) needs these: it verifies the app via silent push (APNs) and
/// falls back to a reCAPTCHA web flow (URL scheme) when push isn't available.
/// Without this wiring the SDK crashes in PhoneAuthProvider (nil unwrap).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        return true
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

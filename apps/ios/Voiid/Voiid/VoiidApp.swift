//
//  VoiidApp.swift
//  Voiid
//
//  Created by Bask Creative on 15/06/26.
//

import SwiftUI
import FirebaseCore

@main
struct VoiidApp: App {
    init() {
        // Reads GoogleService-Info.plist from the app bundle. Required for
        // Firebase Phone Auth (OTP).
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

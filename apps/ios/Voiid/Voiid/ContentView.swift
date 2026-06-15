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
    @StateObject private var clips = ClipsStore()

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
        .environmentObject(clips)
        .tint(VoiidColor.primary)
        .preferredColorScheme(.light)   // fixed light design — identical in light & dark mode
    }
}

#Preview {
    ContentView()
}

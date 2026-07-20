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
    @ObservedObject private var call = CallService.shared

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
        // Global incoming-call surface: an inbound 1:1 call (offer received over the
        // socket) presents the call screen over whatever is on screen.
        .fullScreenCover(isPresented: incomingCallPresented) {
            if let c = call.active {
                CallScreen(request: CallRequest(
                    title: c.title, isGroup: false, members: [], photoName: nil,
                    kind: c.isVideo ? .video : .voice, peerUserId: c.peerUserId))
            }
        }
    }

    /// Present the global call surface only for an INCOMING call (an outgoing call is
    /// already presented from the chat detail screen).
    private var incomingCallPresented: Binding<Bool> {
        Binding(
            get: { call.active?.isOutgoing == false && call.active?.state != .ended },
            set: { _ in }
        )
    }
}

#Preview {
    ContentView()
}

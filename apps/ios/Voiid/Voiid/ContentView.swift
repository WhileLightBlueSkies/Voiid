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
    /// Set when the user taps the PiP window (or the in-app floating window) to
    /// come back to a call whose screen is no longer presented.
    @State private var restoreCallUIRequested = false

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
        // Global incoming-call surface: an inbound 1:1 call (offer received over the
        // socket) presents the call screen over whatever is on screen.
        .fullScreenCover(isPresented: incomingCallPresented) {
            if let c = call.active {
                CallScreen(request: CallRequest(
                    title: c.title, isGroup: false, members: [], photoName: nil,
                    kind: c.isVideo ? .video : .voice, peerUserId: c.peerUserId))
            }
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

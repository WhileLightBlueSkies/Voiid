import Foundation

enum TourDestination: String, CaseIterable, Codable {
    case chats
    case moments
    case communities
    case games
    case settings
}

enum WalkthroughPresentationMode {
    case firstIncompleteVersion
    case everyAppLaunch
}

struct AppWalkthroughStep: Identifiable, Equatable {
    let id: String
    let eyebrow: String
    let title: String
    let message: String
    let symbol: String
    let imageName: String?
    let destination: TourDestination?
    let targetId: String?
}

enum AppWalkthroughPlan {
    static let version = 3
    /// Preview mode for 0.0.3. Change this back after the walkthrough is approved.
    static let presentationMode: WalkthroughPresentationMode = .everyAppLaunch

    static func shouldPresent(completedVersion: Int) -> Bool {
        presentationMode == .everyAppLaunch || completedVersion < version
    }

    static let steps: [AppWalkthroughStep] = [
        .init(
            id: "chats",
            eyebrow: "ENCRYPTED MESSAGING",
            title: "Your people, one tap away",
            message: "Start 1-on-1 chats and group threads secured with quantum-resistant keys. Long-press messages for reactions and quick replies.",
            symbol: "bubble.left.and.bubble.right.fill",
            imageName: "walkthrough_chats_hub",
            destination: .chats,
            targetId: "nav_tab_chats"
        ),
        .init(
            id: "moments",
            eyebrow: "EPHEMERAL STORIES",
            title: "Share what is happening",
            message: "Post photo or video stories that disappear automatically after 24 hours. Control your audience and view replies directly in your chats.",
            symbol: "circle.circle.fill",
            imageName: "walkthrough_moments_camera",
            destination: .moments,
            targetId: "nav_tab_moments"
        ),
        .init(
            id: "communities",
            eyebrow: "SPACES & CLUBS",
            title: "Find your space",
            message: "Discover or create public and private communities. Dive into topic channels, voice lounges, and tournament brackets.",
            symbol: "person.3.fill",
            imageName: "walkthrough_communities_spaces",
            destination: .communities,
            targetId: "nav_tab_communities"
        ),
        .init(
            id: "community_search",
            eyebrow: "COMMUNITY SEARCH",
            title: "Explore & discover",
            message: "Search for topic spaces by keyword or @handle, explore trending clubs, or start your own public hub in seconds.",
            symbol: "magnifyingglass",
            imageName: "walkthrough_comm_search",
            destination: .communities,
            targetId: "comm_search_bar"
        ),
        .init(
            id: "games",
            eyebrow: "INSTANT PLAY",
            title: "Play together anywhere",
            message: "Jump into lightweight multiplayer games with friends with zero downloads. Complete daily challenges and climb leaderboards.",
            symbol: "gamecontroller.fill",
            imageName: "walkthrough_games_arena",
            destination: .games,
            targetId: "nav_tab_games"
        ),
        .init(
            id: "profile",
            eyebrow: "YOUR IDENTITY",
            title: "Profile & safety",
            message: "Tap your avatar anytime to view your Safety Number, share your QR code, or jump into settings with one touch.",
            symbol: "person.crop.circle",
            imageName: "walkthrough_security_shield",
            destination: .chats,
            targetId: "nav_header_profile"
        ),
        .init(
            id: "settings_page",
            eyebrow: "SETTINGS & PRIVACY",
            title: "You stay in full control",
            message: "Manage double-ratchet keys, linked desktop devices, disappearing message defaults, and export offline backup phrases.",
            symbol: "lock.shield.fill",
            imageName: "walkthrough_security_shield",
            destination: .settings,
            targetId: "settings_profile_card"
        ),
    ]
}

enum WalkthroughAdvance: Equatable {
    case showStep(Int)
    case completed
}

struct AppWalkthroughProgress {
    private(set) var currentIndex = 0
    private(set) var isComplete = false
    private(set) var isSkipped = false
    let stepCount: Int

    init(stepCount: Int, currentIndex: Int = 0) {
        self.stepCount = max(stepCount, 1)
        self.currentIndex = min(max(currentIndex, 0), max(stepCount - 1, 0))
    }

    mutating func advance() -> WalkthroughAdvance {
        guard currentIndex < stepCount - 1 else {
            isComplete = true
            return .completed
        }
        currentIndex += 1
        return .showStep(currentIndex)
    }

    mutating func goBack() -> WalkthroughAdvance {
        currentIndex = max(0, currentIndex - 1)
        return .showStep(currentIndex)
    }

    mutating func skip() {
        isSkipped = true
    }
}

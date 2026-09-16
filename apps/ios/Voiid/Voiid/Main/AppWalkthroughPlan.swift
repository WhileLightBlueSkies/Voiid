import Foundation

enum TourDestination: String, CaseIterable, Codable {
    case chats
    case moments
    case communities
    case games
}

struct AppWalkthroughStep: Identifiable, Equatable {
    let id: String
    let eyebrow: String
    let title: String
    let message: String
    let symbol: String
    let destination: TourDestination?
}

enum AppWalkthroughPlan {
    static let version = 1

    /// The destination list is deliberately explicit. AI, Map and Clips exist in source but
    /// are not present in both platforms' shipped tab sets, so they do not belong here.
    static let steps: [AppWalkthroughStep] = [
        .init(
            id: "welcome", eyebrow: "WELCOME TO VOIID", title: "Everything starts here",
            message: "Private conversations, disappearing moments, communities and games — organised into four simple spaces.",
            symbol: "sparkles", destination: nil
        ),
        .init(
            id: "chats", eyebrow: "CHATS", title: "Your people, one tap away",
            message: "Search, start a chat, create a group, scan a profile code or open Settings from your profile. Long-press messages for replies, reactions and more.",
            symbol: "bubble.left.and.bubble.right.fill", destination: .chats
        ),
        .init(
            id: "moments", eyebrow: "MOMENTS", title: "Share what is happening",
            message: "Post a photo or video for your chosen audience. Moments disappear after 24 hours, and replies return to Chats.",
            symbol: "circle.circle.fill", destination: .moments
        ),
        .init(
            id: "communities", eyebrow: "COMMUNITIES", title: "Find your space",
            message: "Discover or create communities, then explore posts, spaces, members, events and tournaments. Host tools appear only when you are a host.",
            symbol: "person.3.fill", destination: .communities
        ),
        .init(
            id: "games", eyebrow: "GAMES", title: "Play together",
            message: "Browse the live catalogue, accept invites, try daily challenges and follow leaderboards. Each game teaches its own controls when you open it.",
            symbol: "gamecontroller.fill", destination: .games
        ),
        .init(
            id: "privacy", eyebrow: "YOU ARE IN CONTROL", title: "Privacy stays within reach",
            message: "Your profile opens privacy, encrypted backup and recovery, linked devices, storage, notifications, legal information and Help & Support.",
            symbol: "checkmark.shield.fill", destination: nil
        ),
        .init(
            id: "complete", eyebrow: "YOU ARE READY", title: "Make Voiid yours",
            message: "Explore at your own pace. You can replay this walkthrough anytime from Help & Support.",
            symbol: "checkmark.circle.fill", destination: nil
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

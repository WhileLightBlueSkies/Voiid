import Foundation

@main struct ConversationMapCheck {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
        func share(_ id: String, _ chat: String, _ owner: String, _ state: ShareState = .live) -> ConversationLocationParticipant {
            .init(id: id, conversationId: chat, userId: owner, latitude: 12, longitude: 77,
                  state: state, fixedAt: Date(), expiresAt: Date().addingTimeInterval(900), accuracy: 10)
        }
        let android = share("android", "direct", "friend")
        let ios = share("ios", "direct", "me")
        let otherChat = share("unrelated", "other", "another")
        let both = ConversationLocationParticipant.visible([android, ios, otherChat], conversationId: "direct", selected: android)
        check(Set(both.map(\.id)) == ["android", "ios"], "Opening Android bubble includes my iOS share, excludes unrelated chat")
        check(both.count == 2, "Selected share is not duplicated")
        check(ConversationLocationParticipant.visible([android, ios], conversationId: "direct", selected: ios).count == 2,
              "Opening my own bubble also includes Android")
        let group = [share("g1", "group", "a"), share("g2", "group", "b"), share("g3", "group", "me")]
        check(ConversationLocationParticipant.visible(group + [android], conversationId: "group", selected: group[0]).count == 3,
              "Group map contains every active member and no direct-chat share")
        let ended = share("ended", "group", "former", .ended)
        check(!ConversationLocationParticipant.visible(group + [ended], conversationId: "group", selected: group[0]).contains { $0.id == ended.id },
              "Ended peer leaves active group map")
        check(ConversationLocationParticipant.visible(group + [ended], conversationId: "group", selected: ended).first { $0.id == ended.id }?.state == .ended,
              "Opened ended share remains ended with its final position")
        let stale = share("stale", "group", "offline", .stale)
        check(ConversationLocationParticipant.visible([stale], conversationId: "group", selected: nil).count == 1,
              "Stale member remains visible at last-known position")
        check(ConversationLocationParticipant.visible(group, conversationId: nil, selected: android).map(\.id) == ["android"],
              "Missing chat context never exposes unrelated participants")
        print("\(count) conversation map selection checks passed.")
    }
}

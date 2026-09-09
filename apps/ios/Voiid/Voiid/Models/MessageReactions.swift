import Foundation

enum MessageReactions {
    struct Summary: Identifiable, Equatable {
        var id: String { emoji }
        let emoji: String
        let count: Int
        let isMine: Bool
    }

    static func toggled(_ emoji: String, by userId: String, in reactions: [String: String]) -> String? {
        reactions[userId] == emoji ? nil : emoji
    }

    static func summaries(_ reactions: [String: String], myUserId: String?) -> [Summary] {
        let mine = myUserId.flatMap { reactions[$0] }
        return Dictionary(grouping: reactions.values, by: { $0 }).map { emoji, values in
            Summary(emoji: emoji, count: values.count, isMine: emoji == mine)
        }.sorted { $0.emoji < $1.emoji }
    }
}

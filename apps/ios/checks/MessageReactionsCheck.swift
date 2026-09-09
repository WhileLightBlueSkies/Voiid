import Foundation

@main struct MessageReactionsCheck {
    static func main() {
        var reactions = ["peer": "❤️"]
        reactions["me"] = MessageReactions.toggled("❤️", by: "me", in: reactions)
        precondition(reactions == ["peer": "❤️", "me": "❤️"], "Matching a peer must add ours")
        let shared = MessageReactions.summaries(reactions, myUserId: "me")
        precondition(shared.count == 1 && shared[0].count == 2 && shared[0].isMine)
        reactions["me"] = MessageReactions.toggled("❤️", by: "me", in: reactions)
        precondition(reactions == ["peer": "❤️"], "Removing ours must preserve the peer")
        reactions["me"] = MessageReactions.toggled("🔥", by: "me", in: reactions)
        reactions["me"] = MessageReactions.toggled("👍", by: "me", in: reactions)
        precondition(reactions == ["peer": "❤️", "me": "👍"], "Replacement must affect only ours")
        let result = MessageReactions.summaries(reactions, myUserId: "me")
        precondition(result.count == 2 && result.filter(\.isMine).map(\.emoji) == ["👍"])
        precondition(MessageReactions.summaries([:], myUserId: nil).isEmpty)
        print("PASS: per-user add/remove/replace, counts, ownership and empty state")
    }
}

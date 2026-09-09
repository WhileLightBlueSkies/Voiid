import SwiftUI
@main struct ChatQAApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--voice-qa") { VoiceHarness() }
            else { Harness() }
        }
    }
}
struct Harness: View {
    @State private var messages = [
        VMessage(id: "incoming", conversationId: "test", senderId: "peer", text: "Sounds good!", createdAt: .now, reactions: ["peer": "❤️"]),
        VMessage(id: "outgoing", conversationId: "test", senderId: "me", text: "See you soon", createdAt: .now, isMine: true),
        VMessage(id: "long", conversationId: "test", senderId: "peer", text: "This longer message should wrap comfortably across the bubble without the timestamp squeezing every line of text.\nThe second paragraph stays readable too.", createdAt: .now),
        VMessage(id: "quote", conversationId: "test", senderId: "me", text: "Absolutely", createdAt: .now, isMine: true, replyToSender: "Nehal", replyToText: "Can we try the native reactions today?"),
        VMessage(id: "deleted", conversationId: "test", senderId: "peer", text: "Deleted", createdAt: .now, deletedForEveryone: true)
    ]
    @State private var action = "Ready"
    @State private var groups = MessageDayGroups<VMessage>(date: \.createdAt)
    private var groupedMessages: [VMessage] { groups.groups(messages).flatMap { $0.1 } }
    var body: some View {
        NavigationStack {
            VStack {
                Text(action).accessibilityIdentifier("lastAction")
                if ProcessInfo.processInfo.arguments.contains("--updates-qa") {
                    Button("Deliver") { messages[1].status = .delivered }
                    Button("Read") { messages[1].status = .read }
                    Button("Tombstone") { messages[1].deletedForEveryone = true; messages[1].reactions = [:] }
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(groupedMessages) { message in
                            MessageBubble(message: message, isGroup: false, onTapImage: { _ in },
                                onReply: { action = "Reply \(message.id)" },
                                onForward: { action = "Forward" },
                                onReact: { emoji in
                                    let index = messages.firstIndex { $0.id == message.id }!
                                    messages[index].reactions["me"] = MessageReactions.toggled(emoji, by: "me", in: messages[index].reactions)

                                },
                                onCopy: { action = "Copied" }, onInfo: { action = "Info" },
                                onDelete: { action = "Delete" }, onSelect: { action = "Select" })
                        }
                    }.padding(16)
                }
            }
            .background(VoiidColor.background)
            .navigationTitle("Option A · Voiid")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

import SwiftUI
struct VoiceHarness: View {
    @State private var action = "Ready"
    @State private var drag: CGFloat = 0
    private var accessibilitySize: Bool { ProcessInfo.processInfo.arguments.contains("--large-text") }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text(action).accessibilityIdentifier("lastAction")
                    voice("incoming", mine: false)
                    voice("outgoing", mine: true)
                    voice("missing", mine: false)
                    RecordingBar(seconds: 72, dragX: drag) { action = "Recording deleted" }
                    Slider(value: $drag, in: -110...0).accessibilityIdentifier("cancel.drag")
                }
                .frame(maxWidth: 288)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .background(VoiidColor.background)
            .navigationTitle("Voice messages")
            .navigationBarTitleDisplayMode(.inline)
        }
        .dynamicTypeSize(accessibilitySize ? .accessibility3 : .large)
    }
    private func voice(_ id: String, mine: Bool) -> some View {
        MessageBubble(message: VMessage(id: id, conversationId: "test", senderId: mine ? "me" : "peer",
            kind: .voice, text: "Voice message", createdAt: .now, isMine: mine,
            replyToSender: mine ? "Nehal" : nil, replyToText: mine ? "Can you send a voice note?" : nil,
            mediaRef: MediaRef(mediaUrl: "qa-\(id)")), isGroup: false,
            onTapImage: { _ in }, onReply: { action = "Reply \(id)" })
    }
}

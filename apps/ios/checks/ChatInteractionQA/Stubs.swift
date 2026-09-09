// Only non-text services/content are stubbed; bubble, menus, palette, badges and theme
// are copied from production by prepare.py. This harness never contacts a server.
import SwiftUI
struct MediaRef: Hashable { var mediaUrl: String }
struct LocationRef: Hashable {}
struct VPoll: Hashable {}
final class TokenStore { static let shared = TokenStore(); var userId: String? = "me" }
final class UserDirectory {
    static let shared = UserDirectory()
    struct User { var username: String? }
    func photoURL(_ id: String) -> String? { nil }
    func user(_ id: String) -> User? { nil }
}
struct ProfileAvatarButton: View {
    var photoURL: String?; var name: String; var size: CGFloat
    var body: some View { Circle().frame(width: size, height: size) }
}
struct StoryQuoteView: View {
    var storyId: String; var authorId: String?; var createdAt: Date?
    var accent: Color; var secondary: Color; var fill: Color
    var body: some View { Text("Story") }
}
struct CallLogBubble: View {
    var log: VCallLog; var onTap: () -> Void
    var body: some View { Text("Call") }
}
enum GameInvite {
    struct Parsed {}
    static func isInvite(_ text: String) -> Bool { false }
    static func parse(_ text: String) -> Parsed? { nil }
}
struct GameInviteBubble: View {
    var message: VMessage; var invite: GameInvite.Parsed
    var body: some View { Text("Game") }
}
struct AsyncMediaImage: View {
    var ref: MediaRef; var onTap: (UIImage) -> Void
    var body: some View { Color.blue.frame(width: 200, height: 200) }
}
struct PollBubble: View {
    var poll: VPoll; var onVote: (String) -> Void
    var body: some View { Text("Poll") }
}
struct LocationPinBubble: View {
    var ref: LocationRef; var conversationId: String
    var body: some View { Text("Location") }
}
struct BouncyEmojiStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.frame(minWidth: 44, minHeight: 44) }
}

@MainActor final class MediaCache {
    static let shared = MediaCache()
    private var bytes: [String: Data] = [:]
    func data(_ key: String) -> Data? { bytes[key] }
    func setData(_ value: Data, _ key: String) { bytes[key] = value }
}
@MainActor final class ChatEngine {
    static let shared = ChatEngine()
    func fetchMedia(_ ref: MediaRef) async throws -> Data {
        guard !ref.mediaUrl.contains("missing") else { throw CocoaError(.fileReadNoSuchFile) }
        // A synthetic silent PCM fixture, decoded by the actual AVAudioPlayer.
        let samples = 8000 * 20
        var bytes = Data()
        func string(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { bytes.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { bytes.append(contentsOf: $0) } }
        string("RIFF"); u32(UInt32(36 + samples * 2)); string("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        string("data"); u32(UInt32(samples * 2)); bytes.append(Data(count: samples * 2))
        return bytes
    }
}

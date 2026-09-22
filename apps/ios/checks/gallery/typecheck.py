from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[4]
s = (root / 'apps/ios/Voiid/Voiid/Main/Media/ChatMediaViewer.swift').read_text()
stubs='''
@MainActor enum VoiidColor { static let accentInk = Color.teal; static let accent = Color.teal }
extension UIFont { static func voiidRounded(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont { .systemFont(ofSize: size, weight: weight) } }
struct MediaRef: Equatable { let mediaUrl: String; let mime: String }
struct ChatMediaItem: Equatable { enum Kind { case image, video }; let id: String; let ref: MediaRef; let type: Kind; let sentAt: Date; let displayName: String; let caption: String?; let isOutgoing: Bool; let durationLabel: String? }
@MainActor class ChatStore: ObservableObject {}
@MainActor enum ChatMediaStore { static func items(chatId: String, from: ChatStore) -> [ChatMediaItem] { [] } }
@MainActor final class TokenStore { static let shared = TokenStore(); var userId: String? }
@MainActor final class MediaCache { static let shared = MediaCache(); func data(_ key: String) -> Data? { nil }; func setData(_ data: Data, _ key: String) {}; func fileURL(_ key: String) -> URL? { nil }; func image(_ key: String) -> UIImage? { nil }; func set(_ image: UIImage, _ key: String) {} }
@MainActor final class ChatEngine { static let shared = ChatEngine(); func fetchMedia(_ ref: MediaRef) async throws -> Data { Data() } }
@MainActor final class ChatMediaThumbnails { static let shared = ChatMediaThumbnails(); func thumbnail(for: ChatMediaItem, side: CGFloat, displayScale: CGFloat) async -> UIImage? { nil } }
'''
with tempfile.TemporaryDirectory(prefix='voiid-gallery-check-') as temp:
    source = Path(temp) / 'Gallery.swift'
    source.write_text(s + '\n' + stubs)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'iphoneos', 'swiftc', '-typecheck', '-target',
                    'arm64-apple-ios18.0', '-sdk', sdk, '-default-isolation', 'MainActor',
                    '-module-cache-path', '/tmp/voiid-document-ios-cache', str(source)], check=True)
    print('Gallery iOS SDK type-check passed (app services stubbed; no app built).')

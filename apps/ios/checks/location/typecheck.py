from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[4] / 'apps/ios/Voiid/Voiid'
stubs='''
@MainActor enum VoiidColor { static let textSecondary = Color.gray; static let textPrimary = Color.primary; static let accentInk = Color.teal; static let accent = Color.teal; static let accentTint = Color.teal.opacity(0.1); static let background = Color.white; static let fieldFill = Color.gray.opacity(0.1); static let surfaceCard = Color.white; static let textOnAccent = Color.white }
@MainActor enum VoiidFont { static func rounded(_ size: CGFloat, _ weight: Font.Weight) -> Font { .system(size: size, weight: weight, design: .rounded) } }
@MainActor enum Haptics { static func selection() {}; static func success() {} }
@MainActor final class LocationShareEngine: ObservableObject {
 static let shared = LocationShareEngine()
 @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
 @Published var isReducedAccuracy = false
 @Published var lastError: String?
 func requestAlways() {}
}
'''
files=['Main/LocationComposeSheet.swift','Networking/LocationService.swift','Models/LocationModels.swift']
with tempfile.TemporaryDirectory(prefix='voiid-location-ui-') as temp:
    source = Path(temp) / 'Location.swift'
    source.write_text('\n'.join((root/f).read_text() for f in files) + stubs)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'iphoneos', 'swiftc', '-typecheck', '-target',
                    'arm64-apple-ios18.0', '-sdk', sdk, '-default-isolation', 'MainActor',
                    '-module-cache-path', '/tmp/voiid-document-ios-cache', str(source)], check=True)
    print('Location picker and Core Location service iOS SDK type-check passed.')

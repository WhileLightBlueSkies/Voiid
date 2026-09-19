// Standalone macOS checks use real game/physics sources; only UIKit feedback is stubbed.
import SwiftUI

enum Haptics {
    static func rigid() {}
    static func soft() {}
    static func error() {}
    static func boundary() {}
    static func success() {}
}

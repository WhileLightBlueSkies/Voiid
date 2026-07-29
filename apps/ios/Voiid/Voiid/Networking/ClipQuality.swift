//
//  ClipQuality.swift
//  Voiid
//
//  The three video renditions a clip is published in, and how one gets chosen.
//
//  WHY THREE AND NOT ADAPTIVE STREAMING: true ABR (HLS/DASH) needs the source segmented
//  into chunks plus a manifest, which in practice means handing transcoding to a
//  service. Three fixed renditions produced ON-DEVICE need no new backend at all — the
//  phone already has the encoder, and the app already has presign+PUT. The trade is that
//  quality is chosen ONCE per playback rather than switching mid-stream.
//

import Foundation
import Network
import Combine
import CoreGraphics

enum ClipQuality: String, CaseIterable, Codable, Hashable {
    case sd     // ~480p — metered/cellular, or a weak connection
    case hd     // ~720p — the default; what most phone screens actually resolve
    case fhd    // ~1080p — wifi and a large screen

    /// Long edge in pixels. The exporter never UPSCALES past the source, so a 720p
    /// original simply produces no `.fhd` rendition (see ClipExporter.exportLadder).
    var longEdge: CGFloat {
        switch self {
        case .sd: return 854
        case .hd: return 1280
        case .fhd: return 1920
        }
    }

    /// Target average bitrate. Chosen so a 90s clip stays well inside the 100 MB cap:
    /// 90s at 4.5 Mbps ≈ 50 MB, leaving headroom for audio and container overhead.
    var bitrate: Int {
        switch self {
        case .sd: return 1_200_000
        case .hd: return 2_800_000
        case .fhd: return 4_500_000
        }
    }

    var label: String {
        switch self {
        case .sd: return "480p"
        case .hd: return "720p"
        case .fhd: return "1080p"
        }
    }
}

/// Watches the current path so playback can pick a rendition without blocking on a
/// probe at the moment the user taps a tile.
///
/// This is deliberately coarse. `isExpensive` (cellular/hotspot) and `isConstrained`
/// (Low Data Mode) are the two signals iOS actually gives us; there is no reliable
/// bandwidth estimate before bytes move, and guessing one would be worse than honest
/// coarse buckets.
@MainActor
final class ClipNetworkMonitor: ObservableObject {
    static let shared = ClipNetworkMonitor()

    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false
    @Published private(set) var isWifi = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "voiid.clips.network")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isExpensive = path.isExpensive
                self?.isConstrained = path.isConstrained
                self?.isWifi = path.usesInterfaceType(.wifi)
            }
        }
        monitor.start(queue: queue)
    }

    /// The rendition to request for fullscreen playback right now.
    ///
    /// Low Data Mode is respected as a hard floor: the user has explicitly asked the
    /// system to conserve, and quietly streaming 1080p over that would be a bug the
    /// user cannot see but pays for.
    var preferredQuality: ClipQuality {
        if isConstrained { return .sd }
        if isExpensive { return .sd }
        return isWifi ? .fhd : .hd
    }
}

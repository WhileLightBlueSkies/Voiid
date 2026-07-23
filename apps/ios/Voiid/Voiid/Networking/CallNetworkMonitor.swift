//
//  CallNetworkMonitor.swift
//  Voiid
//
//  Watches the device's network path so an in-progress call can react to a
//  handover (WiFi -> cellular and back, or a dead path coming back to life).
//
//  WHY: WebRTC's local ICE candidates are bound to the interface they were
//  gathered on. When iOS migrates the default route the old candidate pair goes
//  silent and the call dies ~10-30s later with an ICE failure. The only fix is
//  to re-gather (an ICE restart), and the only reliable signal that it's needed
//  is the OS telling us the path changed — `RTCIceConnectionState` finds out far
//  too late.
//
//  This class is deliberately dumb: it detects and reports. CallService decides
//  whether a restart is warranted.
//
//  RUNTIME CAVEAT: the iOS Simulator inherits the Mac's network stack and does
//  not emulate a WiFi/cellular handover, so the transition path here is
//  compile-verified and reasoned, not observed.
//

import Foundation
import Network

/// A coarse description of the current path, enough to notice a handover.
struct CallNetworkPath: Equatable {
    var isSatisfied: Bool
    /// nil when unsatisfied or on an interface type we don't classify.
    var interface: NWInterface.InterfaceType?
    var isExpensive: Bool
    var isConstrained: Bool

    /// A handover is a change that plausibly invalidates our ICE candidates:
    /// the interface type changed, or connectivity was restored after a gap.
    /// Cost/constraint flags flipping on the same interface is NOT a handover.
    func isHandover(from old: CallNetworkPath) -> Bool {
        guard isSatisfied else { return false }         // going offline isn't actionable
        if !old.isSatisfied { return true }              // came back from offline
        return interface != old.interface
    }
}

/// Reports network path transitions on the main actor.
final class CallNetworkMonitor {
    static let shared = CallNetworkMonitor()

    /// Fired on the main actor for every *meaningful* transition (see
    /// `CallNetworkPath.isHandover`), plus the raw new path for logging.
    /// `isHandover` tells the caller whether re-gathering ICE is warranted.
    var onPathChange: ((_ path: CallNetworkPath, _ isHandover: Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.voiid.network.path")
    private var started = false
    private var current: CallNetworkPath?

    /// The last known path. Safe to read from the main actor.
    private(set) var latest: CallNetworkPath?

    private init() {}

    /// Idempotent. Started once at app configure time and left running — the
    /// handler is a no-op when nothing cares, and NWPathMonitor is cheap.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let snapshot = CallNetworkPath(
                isSatisfied: path.status == .satisfied,
                interface: Self.classify(path),
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            Task { @MainActor in self.deliver(snapshot) }
        }
        monitor.start(queue: queue)
    }

    @MainActor
    private func deliver(_ snapshot: CallNetworkPath) {
        let previous = current
        current = snapshot
        latest = snapshot
        guard let previous else { return }   // first sample is a baseline, not a change
        guard snapshot != previous else { return }
        onPathChange?(snapshot, snapshot.isHandover(from: previous))
    }

    /// The interface backing the default route, preferring the ordered list
    /// NWPath gives us (first available is the one in use).
    private static func classify(_ path: NWPath) -> NWInterface.InterfaceType? {
        guard path.status == .satisfied else { return nil }
        for type: NWInterface.InterfaceType in [.wifi, .cellular, .wiredEthernet, .loopback, .other]
        where path.usesInterfaceType(type) {
            return type
        }
        return nil
    }
}

extension NWInterface.InterfaceType {
    /// Short label for logs. Never sent to the backend (see the privacy rules on
    /// CallMetrics) — network identity is not ours to report.
    var voiidLabel: String {
        switch self {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "ethernet"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }
}

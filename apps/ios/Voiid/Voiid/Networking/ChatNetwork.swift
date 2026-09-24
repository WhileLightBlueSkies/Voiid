//
//  ChatNetwork.swift
//  Voiid
//
//  Whether the phone has a route to the internet, for chat sends.
//
//  A send that cannot go yet is never shown as a failure: the bubble keeps its clock, says
//  "Waiting for network" while there is no connection, and goes the moment one returns.
//  `generation` ticks up each time the connection comes back, so anything waiting between
//  retries can stop waiting and try at once.
//

import Foundation
import Network
import Combine

@MainActor
final class ChatNetwork: ObservableObject {
    static let shared = ChatNetwork()

    /// True while the system reports a usable path. Starts true so nothing reads "offline"
    /// before the first update arrives.
    @Published private(set) var isReachable = true
    /// Bumped on every offline → online change.
    @Published private(set) var generation = 0

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor in
                guard let self, reachable != self.isReachable else { return }
                self.isReachable = reachable
                if reachable { self.generation += 1 }
            }
        }
        monitor.start(queue: DispatchQueue(label: "voiid.chat.network"))
    }

    /// Sleep up to `seconds`, returning early if the connection comes back meanwhile.
    func wait(seconds: Double) async {
        let start = generation
        var left = seconds
        while left > 0, generation == start, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            left -= 0.5
        }
    }
}

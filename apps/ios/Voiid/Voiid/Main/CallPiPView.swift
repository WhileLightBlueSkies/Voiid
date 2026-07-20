//
//  CallPiPView.swift
//  Voiid
//
//  SwiftUI host for the shared `AVSampleBufferDisplayLayer` that renders remote
//  call video. The SAME layer instance is used everywhere — full-screen in the
//  call UI, in the in-app floating window, and by the system PiP window — so the
//  video never has to be torn down and re-attached when it moves between them
//  (that would cause a black flash and drop frames).
//

import SwiftUI
import UIKit

/// Renders the remote participant's video from `CallPiPController`'s shared
/// sample-buffer layer. Use this instead of `RTCVideoView` for the remote track
/// of a 1:1 video call — it is what makes Picture-in-Picture possible.
struct CallRemoteVideoView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        CallRemoteVideoView.reparentHostView(into: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Re-claim the shared view if another host (the floating window, a
        // previous call screen) took it since we were built.
        let host = CallPiPController.shared.hostView
        if host.superview !== uiView {
            CallRemoteVideoView.reparentHostView(into: uiView)
        }
    }

    /// Moves the one shared host view into `container` and pins it. Moving rather
    /// than recreating keeps the renderer attached to the track.
    static func reparentHostView(into container: UIView) {
        let host = CallPiPController.shared.hostView
        host.removeFromSuperview()
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

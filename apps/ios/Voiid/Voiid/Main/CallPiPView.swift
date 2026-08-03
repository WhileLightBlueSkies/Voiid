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
        let container = HostContainer()
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

    /// RE-CLAIM ON EVERY LAYOUT PASS, not only when SwiftUI decides to update.
    ///
    /// THE BLACK SCREEN AFTER RESTORING A MINIMIZED VIDEO CALL. There is ONE shared host view
    /// and it lives wherever it was last parented. Minimizing hands it to the floating
    /// window; dismissing that window calls `removeFromSuperview()`, so the host is left
    /// ORPHANED — attached to the renderer and the track, but in no view hierarchy.
    ///
    /// Returning to the call screen does not necessarily rebuild it: if SwiftUI reuses the
    /// existing representable, `makeUIView` never runs again, and `updateUIView` only runs
    /// when SwiftUI thinks something changed. Nothing did — the state that matters changed
    /// in UIKit, invisibly to SwiftUI — so nobody re-parented the host and the user got a
    /// black rectangle where the remote video should be.
    ///
    /// `layoutSubviews` fires when the view is laid out, which restoring always does. Cheap:
    /// the guard makes it a no-op in the normal case.
    final class HostContainer: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            let host = CallPiPController.shared.hostView
            if host.superview !== self {
                CallRemoteVideoView.reparentHostView(into: self)
            }
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

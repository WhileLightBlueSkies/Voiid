//
//  CallFloatingWindow.swift
//  Voiid
//
//  In-app floating call window ("return to call"): when a call is live but the
//  full-screen call UI is not on screen — the user navigated back into chats
//  while still talking — a small draggable window hovers above the app. Tapping
//  it returns to the call.
//
//  This is DISTINCT from system Picture-in-Picture (`CallPiPController`):
//    - This floating window works only while VOIID itself is in the foreground.
//    - System PiP is what keeps remote video alive when the app is BACKGROUNDED.
//  Both share the one `AVSampleBufferDisplayLayer` host view, which is MOVED
//  between hosts rather than recreated, so the WebRTC renderer stays attached to
//  the remote track across every transition (no black frames, no renegotiation).
//
//  Implemented in UIKit on its own `UIWindow` because it has to float above
//  whatever SwiftUI hierarchy the user navigates to, while letting touches
//  outside the pill fall through to the app underneath.
//
//  RUNTIME CAVEAT: compile-verified only. Window layering, dragging and the
//  hand-off to/from PiP need a real device on a live call to confirm.
//

import UIKit
import Combine
import SwiftUI

// MARK: - Passthrough window

/// A window that is invisible to touches except where its floating pill is, so
/// the app underneath stays fully interactive.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // The root view itself is just empty space — only the pill consumes touches.
        return hit === rootViewController?.view ? nil : hit
    }
}

// MARK: - The floating pill

/// The draggable card. Hosts either the shared remote-video view (video calls)
/// or a compact "tap to return" pill (voice calls).
private final class FloatingCallPill: UIView {
    /// Called when the user taps to return to the call.
    var onTap: (() -> Void)?

    private static let videoSize = CGSize(width: 90, height: 160)
    /// A CIRCLE, not a 148×56 bar.
    ///
    /// The bar read as a BANNER — the shape of something you dismiss, not something you tap
    /// to go back — and it covered a strip of whatever was underneath. A round bubble reads
    /// as a live object, takes a fraction of the space, and is the shape every messenger uses
    /// for this state. Matches Android's minimized bubble.
    private static let voiceSize = CGSize(width: 64, height: 64)
    private static let margin: CGFloat = 12

    private let isVideo: Bool

    /// Lets the manager find the timer label without holding a reference to it.
    static let timerLabelTag = 9_101

    /// Update the bubble's elapsed-time label.
    func setElapsed(_ seconds: Int) {
        guard let label = viewWithTag(Self.timerLabelTag) as? UILabel else { return }
        label.text = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    init(isVideo: Bool, title: String) {
        self.isVideo = isVideo
        super.init(frame: CGRect(origin: .zero,
                                 size: isVideo ? Self.videoSize : Self.voiceSize))
        // GREEN for voice, black for video.
        //
        // Black was right when this was a video-first window — it is the letterbox behind a
        // remote frame. On a voice bubble it reads as an empty hole, and it did not match
        // Android's green. Green is the universal "call in progress" colour, and it is what
        // makes the bubble legible as a live call rather than a floating dot.
        backgroundColor = isVideo ? .black : UIColor(VoiidColor.success)
        // Fully round for voice (a circle), softly rounded for video (which has a frame to
        // show and would crop badly in a circle).
        layer.cornerRadius = isVideo ? 14 : Self.voiceSize.width / 2
        layer.cornerCurve = .continuous
        clipsToBounds = true
        // The hairline exists to give a BLACK video window an edge against dark content. On
        // the green bubble the fill already provides that, and a white ring on green reads as
        // an unintended outline.
        layer.borderWidth = isVideo ? 1 : 0
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        // A shadow needs to escape the clipped corners, so it lives on the
        // container's layer via a shadow path on this view's own layer instead.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)

        if isVideo {
            // Take over the one shared sample-buffer host view.
            CallRemoteVideoView.reparentHostView(into: self)
        } else {
            addSubview(makeVoiceContent(title: title))
        }

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func makeVoiceContent(title: String) -> UIView {
        // VERTICAL, for a circle. The old horizontal icon+name stack was built for a 148pt
        // bar; in a 64pt circle a name truncates to two characters and says nothing.
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        // INSET, not the full bounds. A circle's usable area is its inscribed square — laying
        // content out to the full 64pt bounds put the icon and timer hard against the curve,
        // which is why the contents looked wrong rather than centred.
        stack.frame = bounds.insetBy(dx: 10, dy: 10)
        stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let icon = UIImageView(image: UIImage(systemName: "phone.fill"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        // The TIMER, not the name — "how long have I been on this call" is the fact worth
        // surfacing in the space a circle actually has. Updated by the manager.
        let label = UILabel()
        label.tag = Self.timerLabelTag
        label.text = "0:00"
        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textAlignment = .center

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        return stack
    }

    // MARK: gestures

    @objc private func handleTap() { onTap?() }

    private var panOrigin: CGPoint = .zero

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let parent = superview else { return }
        switch gesture.state {
        case .began:
            panOrigin = center
        case .changed:
            let t = gesture.translation(in: parent)
            center = CGPoint(x: panOrigin.x + t.x, y: panOrigin.y + t.y)
        case .ended, .cancelled:
            snapIntoBounds(of: parent, animated: true)
        default:
            break
        }
    }

    /// Keep the pill fully on screen, snapped to the nearer side edge.
    func snapIntoBounds(of parent: UIView, animated: Bool) {
        let safe = parent.safeAreaInsets
        let minX = Self.margin + safe.left + bounds.width / 2
        let maxX = parent.bounds.width - Self.margin - safe.right - bounds.width / 2
        let minY = Self.margin + safe.top + bounds.height / 2
        let maxY = parent.bounds.height - Self.margin - safe.bottom - bounds.height / 2
        guard maxX >= minX, maxY >= minY else { return }

        let snappedX = (center.x < parent.bounds.midX) ? minX : maxX
        let target = CGPoint(x: snappedX, y: min(max(center.y, minY), maxY))
        guard animated else { center = target; return }
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.85,
                       initialSpringVelocity: 0.4, options: [.allowUserInteraction]) {
            self.center = target
        }
    }
}

// MARK: - Root VC

private final class FloatingCallRootViewController: UIViewController {
    var pill: FloatingCallPill?

    override func loadView() {
        let v = UIView()
        v.backgroundColor = .clear
        view = v
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pill?.snapIntoBounds(of: view, animated: false)
    }
}

// MARK: - Manager

/// Shows/hides the floating window in step with the call state. Wired up once at
/// startup via `observe(_:)`.
@MainActor
final class CallFloatingWindowManager {
    static let shared = CallFloatingWindowManager()

    private var window: PassthroughWindow?
    private var cancellables = Set<AnyCancellable>()
    private var shownForCallId: String?
    private var shownAsVideo = false

    private init() {}

    /// React to: call state, whether the call screen is up, and whether system
    /// PiP has taken over (never show both at once).
    func observe(_ service: CallService) {
        guard cancellables.isEmpty else { return }

        Publishers.CombineLatest3(
            service.$active,
            service.$callUIVisible,
            CallPiPController.shared.$isPiPActive
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] active, callUIVisible, pipActive in
            self?.update(active: active, callUIVisible: callUIVisible, pipActive: pipActive)
        }
        .store(in: &cancellables)

        // Drive the bubble's timer off the SAME counter the call screen uses, rather than a
        // second clock. Two independent timers drift, and a bubble showing 2:04 while the
        // call screen behind it says 2:07 is the kind of detail that reads as broken.
        service.$connectedSeconds
            .receive(on: RunLoop.main)
            .sink { [weak self] seconds in
                // The pill lives on the window's root VC, not on the manager.
                let root = self?.window?.rootViewController as? FloatingCallRootViewController
                root?.pill?.setElapsed(seconds)
            }
            .store(in: &cancellables)
    }

    private func update(active: ActiveCall?, callUIVisible: Bool, pipActive: Bool) {
        // Only float for a call that is actually up, that nothing else is
        // already showing, and that the system PiP window hasn't claimed.
        guard let call = active,
              call.state == .connected || call.state == .connecting,
              !callUIVisible,
              !pipActive else {
            hide()
            return
        }
        // Rebuild if the call (or its video-ness) changed; otherwise leave the
        // existing pill alone so it keeps its dragged position.
        let isVideo = call.isVideo && CallService.shared.remoteVideoTrack != nil
        if shownForCallId == call.id && shownAsVideo == isVideo { return }
        hide()
        show(call: call, isVideo: isVideo)
    }

    private func show(call: ActiveCall, isVideo: Bool) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let root = FloatingCallRootViewController()
        let w = PassthroughWindow(windowScene: scene)
        w.rootViewController = root
        w.backgroundColor = .clear
        // Above ordinary app content, below system alerts.
        w.windowLevel = .alert - 1
        w.isHidden = false

        let pill = FloatingCallPill(isVideo: isVideo, title: call.title)
        pill.onTap = { NotificationCenter.default.post(name: .voiidRestoreCallUI, object: nil) }
        root.pill = pill
        root.view.addSubview(pill)
        // Start top-trailing; the user can drag it anywhere.
        pill.center = CGPoint(x: root.view.bounds.width - pill.bounds.width,
                              y: pill.bounds.height)
        root.view.setNeedsLayout()

        window = w
        shownForCallId = call.id
        shownAsVideo = isVideo
    }

    private func hide() {
        guard window != nil else { return }
        // Do NOT destroy the shared video host view — the call screen (or PiP)
        // takes it back. Just drop it out of this window's hierarchy.
        if shownAsVideo { CallPiPController.shared.hostView.removeFromSuperview() }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        shownForCallId = nil
        shownAsVideo = false
    }
}

//
//  TabSwipeNavigation.swift
//  Voiid
//
//  Swipe left/right anywhere on a tab's content to move to the next or previous tab.
//
//  ── WHY THIS IS SAFE TO ADD, GIVEN THE CROSSFADE NOTE ───────────────────────────
//  RootTabView's transition comment rejects a slide because "these tabs are scrollable and
//  reorderable, so there is no stable left-of/right-of between them." The scrollable half is
//  true — the BAR scrolls — but the reorderable half is not: the bar renders
//  `Tab.allCases`, a fixed compile-time order, and nothing in the app permutes it. So a
//  stable left/right genuinely exists, and a swipe can make a spatial claim it can keep.
//
//  The crossfade stays for TAPS. Tapping a distant tab jumps an arbitrary distance and a
//  slide would have to invent a direction for it; a swipe moves exactly one step, so the
//  direction is not invented — it is the gesture. Two transitions for two different
//  intentions, each honest about what it is describing.
//
//  ── WHY A UIKIT PAN AND NOT A SWIFTUI DragGesture ───────────────────────────────
//  Tab content is full of horizontal ScrollViews (community rails, highlight rails, filter
//  rails). A SwiftUI `DragGesture` on the container competes with every one of them, and the
//  loser is decided by gesture priority rather than by intent — the usual result is that
//  either the rails stop scrolling or the tab swipe never fires.
//
//  A UIPanGestureRecognizer with a delegate can defer properly: it FAILS if the touch begins
//  inside a horizontal scroll view that can still scroll in the swipe's direction, so rails
//  keep working, and it only claims the gesture when the touch is somewhere a horizontal
//  drag means nothing else.
//
//  ── FOLLOWS THE FINGER ──────────────────────────────────────────────────────────
//  The page tracks the drag 1:1 rather than waiting for release and then animating. Feedback
//  during the interaction is the whole difference between a gesture and a shortcut, and it
//  is also what makes the swipe reversible: drag halfway, change your mind, drag back.
//
//  At the ends of the range the drag RUBBER-BANDS instead of stopping dead — a hard stop
//  reads as frozen, resistance reads as "responsive, but there is nothing more here."
//
//  On release the landing tab is chosen from PROJECTED momentum, not from where the finger
//  happened to be: a fast flick commits even if it barely moved, which is what makes a flick
//  feel like a throw. The spring then starts at the finger's release velocity so there is no
//  seam between dragging and animating.
//

import SwiftUI
import UIKit

struct TabSwipeNavigation<T: Hashable>: ViewModifier {

    @Binding var selection: T
    let ordered: [T]
    /// True for the life of a swipe-driven change, so the host's crossfade stands down.
    @Binding var swiping: Bool

    /// Live drag offset, OWNED BY THE HOST so it can move both pages as one strip. This
    /// modifier no longer offsets the content itself: offsetting from out here could only
    /// ever move the single mounted page, which is what left the window showing behind it.
    @Binding var dragX: CGFloat
    /// The tab being dragged toward. Publishing it is what mounts the neighbour.
    @Binding var toward: T?
    @State private var width: CGFloat = 1

    private var index: Int { ordered.firstIndex(of: selection) ?? 0 }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { width = max(geo.size.width, 1) }
                        .onChange(of: geo.size.width) { _, w in width = max(w, 1) }
                }
            )

            // BACKGROUND, not overlay, and zero-sized.
            //
            // An overlay that stays in the hit-test chain BECOMES the hit view, so every tap
            // would land on it instead of the button underneath. This instead installs the
            // recogniser on the enclosing view controller's own view — the whole page — so
            // it observes touches across the content without occupying any of it.
            .background(
                PanCatcher(
                    onChange: { translation in
                        let x = rubberBanded(translation)
                        // Published BEFORE the offset moves far, so the neighbour is already
                        // mounted and laid out by the time any of it is on screen.
                        let next = x < 0 ? index + 1 : index - 1
                        toward = ordered.indices.contains(next) ? ordered[next] : nil
                        dragX = x
                    },
                    onEnd: { translation, velocity in
                        commit(translation: translation, velocity: velocity)
                    }
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            )
    }

    /// Resistance past the first and last tab. `0.55` is the constant UIScrollView uses.
    private func rubberBanded(_ raw: CGFloat) -> CGFloat {
        let atStart = index == 0 && raw > 0
        let atEnd = index == ordered.count - 1 && raw < 0
        guard atStart || atEnd else { return raw }
        let over = abs(raw)
        let damped = (over * width * 0.55) / (width + 0.55 * over)
        return raw < 0 ? -damped : damped
    }

    private func commit(translation: CGFloat, velocity: CGFloat) {
        // Project where the drag was GOING, not where it stopped. Apple's deceleration form
        // from Designing Fluid Interfaces — a flick with barely any travel still commits.
        let projected = translation + (velocity / 1000) * 0.998 / (1 - 0.998)

        // A third of the screen, or any projection that clears it. Deliberately not a
        // velocity-only test: a slow, deliberate long drag should also commit.
        let threshold = width / 3
        var target = index
        if projected < -threshold { target = min(index + 1, ordered.count - 1) }
        else if projected > threshold { target = max(index - 1, 0) }

        // ── CANCELLED: spring home ────────────────────────────────────────────
        guard target != index else {
            let initial = abs(velocity) / max(abs(dragX), 1)
            withAnimation(.interpolatingSpring(stiffness: 320, damping: 30,
                                               initialVelocity: initial)) {
                dragX = 0
            }
            // Cleared after the spring settles, not immediately: unmounting the neighbour
            // while it is still sliding back into view is the black flash in miniature.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                if dragX == 0 { toward = nil }
            }
            return
        }

        // ── COMMITTED ─────────────────────────────────────────────────────────
        //
        // ONE continuous motion now, because both pages are mounted: the strip slides by
        // exactly one screen width and the incoming page is already in place beside the
        // outgoing one. There is no moment when nothing occupies the screen, which is what
        // the black flash was — the old page pushed off with nothing behind it.
        //
        // The selection swap happens at the END, with animations disabled, and `dragX` is
        // zeroed in the same transaction. Both pages are already exactly where they need to
        // be at that instant, so the swap is invisible: the strip stops, and the page that
        // was the neighbour simply becomes the current one.
        let goingLeft = target > index
        Haptics.selection()
        swiping = true

        let destination = goingLeft ? -width : width
        let remaining = max(abs(destination - dragX), 1)
        withAnimation(.interpolatingSpring(stiffness: 340, damping: 34,
                                           initialVelocity: abs(velocity) / remaining)) {
            dragX = destination
        }

        Task {
            // Matched to the spring's settle time. Swapping earlier cuts the motion short;
            // later leaves the strip parked off-centre.
            try? await Task.sleep(for: .milliseconds(380))
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                selection = ordered[target]
                dragX = 0
                toward = nil
            }
            swiping = false
        }
    }
}

// MARK: - The recogniser

/// A zero-sized view that installs a horizontal `UIPanGestureRecognizer` on the page.
private struct PanCatcher: UIViewRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, onEnd: onEnd) }

    func makeUIView(context: Context) -> UIView {
        let v = PassthroughView()
        // Attached on the next runloop turn, once this view is in a hierarchy and can find
        // the page it should observe.
        DispatchQueue.main.async { context.coordinator.attach(from: v) }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
        context.coordinator.attach(from: v)
    }

    /// A plain view. It must NOT override `hitTest` to return nil — a view that does is
    /// excluded from the touch's hit-test chain, and UIKit delivers touches only to
    /// recognisers on views IN that chain. That is why the first version never fired.
    private final class PassthroughView: UIView {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (CGFloat) -> Void
        var onEnd: (CGFloat, CGFloat) -> Void
        private weak var attached: UIView?

        init(onChange: @escaping (CGFloat) -> Void, onEnd: @escaping (CGFloat, CGFloat) -> Void) {
            self.onChange = onChange
            self.onEnd = onEnd
        }

        /// Installs the recogniser on the enclosing hosting controller's view — the page —
        /// so it sees touches anywhere on the tab without covering any of it.
        func attach(from anchor: UIView) {
            guard attached == nil,
                  let host = anchor.owningHostingView ?? anchor.window else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.delegate = self
            // Does NOT delay or cancel touches: taps, long presses and vertical scrolls
            // inside the page must behave exactly as they did before this existed.
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            host.addGestureRecognizer(pan)
            attached = host
        }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let t = g.translation(in: view).x
            switch g.state {
            case .changed:
                onChange(t)
            case .ended, .cancelled, .failed:
                onEnd(t, g.velocity(in: view).x)
            default:
                break
            }
        }

        /// The gate that keeps rails working.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let view = pan.view else { return false }

            // Never while a detail screen is pushed. Each tab hosts a NavigationStack and a
            // push reuses the same hosting controller, so without this a horizontal drag on
            // a pushed screen would swap the tab BEHIND it — and it would also fight the
            // interactive pop gesture, which owns horizontal drags there.
            if let nav = view.nearestNavigationController, nav.viewControllers.count > 1 {
                return false
            }
            // Nor while anything is presented over the tab (a sheet, a full-screen cover).
            if let root = view.window?.rootViewController, root.presentedViewController != nil {
                return false
            }

            let v = pan.velocity(in: view)

            // Horizontal intent only. 1.5:1 rather than a bare `>` so a diagonal drag during
            // a vertical scroll — which is most of them — never steals the gesture.
            guard abs(v.x) > abs(v.y) * 1.5 else { return false }

            // ── PAGES WITH THEIR OWN HORIZONTAL MOVEMENT ────────────────────────
            //
            // A touch that lands on a horizontal scroll view belongs to that scroll view for
            // the WHOLE gesture, not just until it runs out of content.
            //
            // The first version only deferred while the rail could still scroll, so a rail
            // sitting at its end handed the tab swipe over mid-drag — one continuous finger
            // movement did two unrelated things, and which one depended on a scroll offset
            // the user cannot see. Worse, the common case is deliberate: someone flicking a
            // rail to its end and flicking again to see more would change tab instead.
            //
            // So: if the touch begins anywhere inside a horizontally scrollable view, this
            // recogniser stands down entirely. Tab swiping remains available from every
            // other part of the page, which is most of it. Scoping a gesture by WHERE it
            // starts is predictable; scoping it by hidden state is not.
            if horizontalScroll(under: pan.location(in: view), in: view) != nil {
                return false
            }

            // Same reasoning for a page that is itself paged horizontally (the fullscreen
            // clip pager, a carousel): its own paging owns horizontal drags.
            if let scroll = anyScroll(under: pan.location(in: view), in: view),
               scroll.isPagingEnabled {
                return false
            }

            return true
        }

        /// Runs alongside other recognisers rather than replacing them, so taps and vertical
        /// scrolling in the page continue to work while a swipe is being evaluated.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// Walks the real view hierarchy at the touch point looking for a horizontally
        /// scrollable scroll view.
        /// Any scroll view under the point, paging or not.
        private func anyScroll(under point: CGPoint, in root: UIView) -> UIScrollView? {
            var hit = root.hitTest(point, with: nil)
            while let v = hit {
                if let s = v as? UIScrollView { return s }
                hit = v.superview
            }
            return nil
        }

        private func horizontalScroll(under point: CGPoint, in root: UIView) -> UIScrollView? {
            var hit = root.hitTest(point, with: nil)
            while let v = hit {
                if let s = v as? UIScrollView,
                   s.contentSize.width > s.bounds.width + 1 { return s }
                hit = v.superview
            }
            return nil
        }
    }
}

extension View {
    /// Swipe horizontally to move one step through `ordered`.
    func tabSwipeNavigation<T: Hashable>(selection: Binding<T>, ordered: [T],
                                         swiping: Binding<Bool>,
                                         drag: Binding<CGFloat>,
                                         toward: Binding<T?>) -> some View {
        modifier(TabSwipeNavigation(selection: selection, ordered: ordered, swiping: swiping,
                                    dragX: drag, toward: toward))
    }
}


private extension UIView {
    /// The navigation controller this view sits inside, if any.
    var nearestNavigationController: UINavigationController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let nav = r as? UINavigationController { return nav }
            if let vc = r as? UIViewController, let nav = vc.navigationController { return nav }
            responder = r.next
        }
        return nil
    }

    /// The nearest enclosing SwiftUI hosting view.
    ///
    /// Walks up to the view controller that owns this view and returns its root view — the
    /// page. Using the WINDOW instead would put the recogniser above the tab bar and every
    /// presented sheet, so a swipe inside a modal would change the tab underneath it.
    var owningHostingView: UIView? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc.view }
            responder = r.next
        }
        return nil
    }
}

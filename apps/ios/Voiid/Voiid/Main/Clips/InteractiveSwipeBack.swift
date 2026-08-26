//
//  InteractiveSwipeBack.swift
//  Voiid
//
//  Restores the edge-swipe-to-go-back gesture on a screen that hides the navigation bar.
//
//  ── WHY THIS IS NEEDED ──────────────────────────────────────────────────────────
//  `navigationBarBackButtonHidden(true)` does not only hide a button: UIKit ties the
//  interactive pop gesture to the presence of that back item, so hiding it silently
//  disables edge-swipe as well. Any screen that draws its own back chevron over a photo —
//  which is the whole reason the bar is hidden — therefore loses the gesture most people
//  actually use to go back, and the loss is invisible until someone tries it.
//
//  ── WHY A DELEGATE AND NOT JUST `isEnabled = true` ──────────────────────────────
//  Re-enabling the recogniser without owning its delegate makes UIKit pop the ROOT view
//  controller when a swipe starts on a screen it thinks has nothing to pop to — the app
//  appears to lose its whole navigation stack. The delegate below gates on
//  `viewControllers.count > 1`, which is the condition UIKit would have checked itself if
//  the back item were still there.
//

import SwiftUI
import UIKit

private struct InteractiveSwipeBack: UIViewControllerRepresentable {

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        // The controller is not in the hierarchy yet at make-time, so the recogniser is
        // claimed on the next runloop turn once it has a navigationController.
        DispatchQueue.main.async { context.coordinator.attach(from: vc) }
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        context.coordinator.attach(from: vc)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var gesture: UIGestureRecognizer?
        /// Whoever owned the delegate before us, restored on teardown so this cannot
        /// permanently take over a recogniser shared by the whole stack.
        private weak var previousDelegate: UIGestureRecognizerDelegate?
        private weak var nav: UINavigationController?

        func attach(from vc: UIViewController) {
            guard let nav = vc.navigationController,
                  let pop = nav.interactivePopGestureRecognizer,
                  pop.delegate !== self else { return }
            self.nav = nav
            self.gesture = pop
            self.previousDelegate = pop.delegate
            pop.delegate = self
            pop.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            // The gate UIKit would apply itself: never try to pop the root.
            (nav?.viewControllers.count ?? 0) > 1
        }

        /// Lets the swipe coexist with the horizontal scroll views on this screen (the
        /// highlights rail). Without this the rail swallows an edge swipe that starts on it.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }

        deinit {
            if let gesture, gesture.delegate === self { gesture.delegate = previousDelegate }
        }
    }
}

extension View {
    /// Restores edge-swipe-to-go-back on a screen that hides the navigation bar.
    func voiidInteractiveSwipeBack() -> some View {
        background(InteractiveSwipeBack().frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

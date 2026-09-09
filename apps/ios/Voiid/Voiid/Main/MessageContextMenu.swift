import SwiftUI
import UIKit

/// Host the bubble inside UIKit so its context-menu recognizer owns the long press.
/// The menu, reaction palettes, preview lift and dismissal are all system components.
struct MessageContextMenu<Content: View>: UIViewControllerRepresentable {
    let message: VMessage
    var isEnabled = true
    var canReact = true
    var myReaction: String?
    var onForward: () -> Void
    var onMoreEmoji: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var onReact: (String) -> Void
    var onReply: () -> Void
    var onCopy: () -> Void
    var onSelect: () -> Void
    var onDelete: () -> Void
    var onInfo: () -> Void
    var onSwipe: ((CGFloat, Bool) -> Void)? = nil
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: hostedContent)
        controller.view.backgroundColor = .clear
        controller.safeAreaRegions = []
        controller.view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        context.coordinator.sourceView = controller.view
        if onSwipe != nil {
            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
            pan.delegate = context.coordinator
            controller.view.addGestureRecognizer(pan)
        }
        // The first long press should not pay the cost of drawing emoji icons.
        ReactionImages.prepare()
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<AnyView>, context: Context) {
        var previous = context.coordinator.parent.message
        var current = message
        previous.reactions = [:]
        current.reactions = [:]
        let traitsChanged = context.coordinator.parent.colorScheme != colorScheme
            || context.coordinator.parent.dynamicTypeSize != dynamicTypeSize
        context.coordinator.parent = self
        // Reactions are outside the lifted view. Do not rebuild media or the preview when
        // a reaction changes while the system menu is dismissing.
        if previous != current || traitsChanged {
            controller.rootView = hostedContent
        }
    }

    private var hostedContent: AnyView {
        AnyView(content()
            .environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, dynamicTypeSize))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIHostingController<AnyView>,
                     context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: CGSize(width: min(proposal.width ?? 300, 300), height: 10_000))
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
        var parent: MessageContextMenu
        weak var sourceView: UIView?

        init(parent: MessageContextMenu) { self.parent = parent }

        // Native voice scrubbing must win over swipe-to-reply. Reject touches on a
        // UIControl before the pan begins, rather than cancelling its tracking later.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                view = current.superview
            }
            return parent.onSwipe != nil && parent.isEnabled
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: sourceView)
            return abs(velocity.x) > abs(velocity.y) * 1.5
                && (parent.message.isMine ? velocity.x < 0 : velocity.x > 0)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer.view is UIScrollView
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let dx = gesture.translation(in: sourceView).x * 0.55
            let offset = parent.message.isMine ? min(0, max(dx, -58)) : max(0, min(dx, 58))
            switch gesture.state {
            case .began, .changed: parent.onSwipe?(offset, false)
            case .ended: parent.onSwipe?(offset, true)
            case .cancelled, .failed: parent.onSwipe?(0, true)
            default: break
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard parent.isEnabled else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.makeMenu()
            }
        }

        private func makeMenu() -> UIMenu {
            var sections: [UIMenuElement] = []
            if parent.canReact {
                let allEmoji = UIAction(title: "All emoji…", image: UIImage(systemName: "plus")) { [weak self] _ in
                    // Present the sheet only after UIKit has put the preview back.
                    self?.afterDismiss = self?.parent.onMoreEmoji
                }
                let more = UIMenu(title: "More reactions", image: UIImage(systemName: "face.smiling"),
                    children: ([ReactionImages.quick] + ReactionImages.more).map(palette) + [allEmoji])
                sections += [palette(ReactionImages.quick), more]
            }
            var actions: [UIAction] = []
            if !parent.message.deletedForEveryone {
                actions = [action("Reply", icon: "arrowshape.turn.up.left", perform: parent.onReply),
                           action("Forward", icon: "arrowshape.turn.up.right", perform: parent.onForward)]
                if !parent.message.text.isEmpty {
                    actions.append(action("Copy", icon: "doc.on.doc", perform: parent.onCopy))
                }
                if parent.message.isMine {
                    actions.append(action("Info", icon: "info.circle", perform: parent.onInfo))
                }
            }
            actions.append(action("Select", icon: "checkmark.circle", perform: parent.onSelect))
            sections.append(UIMenu(options: .displayInline, children: actions))
            sections.append(UIMenu(options: .displayInline, children: [
                action("Delete", icon: "trash", destructive: true, perform: parent.onDelete)
            ]))
            return UIMenu(children: sections)
        }

        private var afterDismiss: (() -> Void)?

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willEndFor configuration: UIContextMenuConfiguration,
                                    animator: UIContextMenuInteractionAnimating?) {
            guard let action = afterDismiss else { return }
            afterDismiss = nil
            if let animator { animator.addCompletion(action) }
            else { action() }
        }

        private func palette(_ emoji: [String]) -> UIMenu {
            UIMenu(options: [.displayInline, .displayAsPalette], children: emoji.map(reaction))
        }

        private func reaction(_ emoji: String) -> UIAction {
            let selected = parent.myReaction == emoji
            let react = parent.onReact
            return UIAction(title: selected ? "Remove \(emoji) reaction" : "React with \(emoji)",
                            image: ReactionImages.image(for: emoji),
                            identifier: UIAction.Identifier("reaction.\(emoji)"),
                            state: selected ? .on : .off) { _ in
                react(emoji)
            }
        }

        private func action(_ title: String, icon: String, destructive: Bool = false,
                            perform: @escaping () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: icon),
                     attributes: destructive ? .destructive : []) { _ in
                perform()
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
            preview()
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
            preview()
        }

        private func preview() -> UITargetedPreview? {
            guard let sourceView else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            return UITargetedPreview(view: sourceView, parameters: parameters)
        }
    }
}

private enum ReactionImages {
    static let quick = ["❤️", "👍", "😂", "😮", "😢", "🙏"]
    static let more = [
        ["🔥", "😍", "🥰", "😘", "🥹", "😊"],
        ["🤣", "😎", "🤩", "🥳", "🤔", "🫡"],
        ["👏", "🙌", "💯", "🎉", "✨", "💔"],
        ["😅", "😭", "😡", "🤯", "👀", "✅"]
    ]
    private static var cache: [String: UIImage] = [:]

    static func prepare() {
        for emoji in quick + more.flatMap({ $0 }) { _ = image(for: emoji) }
    }

    static func image(for emoji: String) -> UIImage {
        if let image = cache[emoji] { return image }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { _ in
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 25)]
            let text = emoji as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (30 - size.width) / 2, y: (30 - size.height) / 2),
                      withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
        cache[emoji] = image
        return image
    }
}

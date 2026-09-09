import SwiftUI
import UIKit

/// Separate layout space keeps chips tappable while UIKit owns the message preview.
struct MessageReactionBadges: View {
    let reactions: [String: String]
    let myUserId: String?
    let messageId: String
    var isEnabled = true
    var onReact: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MessageReactions.summaries(reactions, myUserId: myUserId)) { reaction in
                NativeReactionBadge(reaction: reaction, messageId: messageId,
                                    isEnabled: isEnabled, onReact: onReact)
            }
        }
    }
}

/// A single native accessibility/touch target, including when a count appears or changes.
/// SwiftUI's composed emoji/count label could retain a stale accessibility hit region.
private struct NativeReactionBadge: UIViewRepresentable {
    let reaction: MessageReactions.Summary
    let messageId: String
    let isEnabled: Bool
    let onReact: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.addAction(UIAction { [weak coordinator = context.coordinator] _ in
            guard let parent = coordinator?.parent, parent.isEnabled else { return }
            parent.onReact(parent.reaction.emoji)
        }, for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        button.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        var title = AttributedString(reaction.emoji)
        title.font = UIFont.systemFont(ofSize: 16)
        if reaction.count > 1 {
            var count = AttributedString(" \(reaction.count)")
            count.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
            title += count
        }
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = title
        configuration.baseForegroundColor = UIColor(VoiidColor.textPrimary)
        configuration.contentInsets = .init(top: 0, leading: 9, bottom: 0, trailing: 9)
        configuration.background.backgroundColor = UIColor(reaction.isMine
            ? VoiidColor.accent.opacity(0.14) : VoiidColor.surfaceCard)
        configuration.background.strokeColor = UIColor(reaction.isMine ? VoiidColor.accent : VoiidColor.divider)
        configuration.background.strokeWidth = 1
        configuration.background.cornerRadius = 14
        configuration.background.backgroundInsets = .init(top: 8, leading: 0, bottom: 8, trailing: 0)
        button.configuration = configuration
        button.isEnabled = isEnabled
        button.isAccessibilityElement = true
        button.accessibilityLabel = "\(reaction.emoji), \(reaction.count) reaction\(reaction.count == 1 ? "" : "s")\(reaction.isMine ? ", including yours" : "")"
        button.accessibilityHint = reaction.isMine ? "Remove your reaction" : "Add this reaction"
        button.accessibilityIdentifier = "message.\(messageId).reaction.\(reaction.emoji)"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: max(44, uiView.intrinsicContentSize.width), height: 44)
    }

    final class Coordinator {
        var parent: NativeReactionBadge
        init(parent: NativeReactionBadge) { self.parent = parent }
    }
}

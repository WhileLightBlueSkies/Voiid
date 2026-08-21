//
//  CommunityCreateFlow.swift
//  Voiid
//
//  Creating a community — five steps. Ported from the reference's CreateCommunityFlow.
//
//  ── ONE SHEET, NOT FIVE PUSHES ──────────────────────────────────────────────────
//  The whole wizard lives in a single sheet whose CONTENT swaps per step, rather than a
//  NavigationStack pushing five screens. The progress bar and footer stay put instead of
//  re-animating on every step, and Cancel means one thing throughout — abandon the draft —
//  rather than sometimes meaning "go back one".
//
//  ── EVERY STEP BUT THE FIRST IS SKIPPABLE ───────────────────────────────────────
//  A community needs a name. It does not need Spaces, rules or invites before it exists, and
//  demanding them is how a create flow gets abandoned at step 3. Each of those ships a working
//  default, so skipping produces a real community rather than an empty one.
//
//  ── UI ONLY, FOR NOW ────────────────────────────────────────────────────────────
//  `onCreate` hands the finished draft back and nothing here calls the API. Wiring it needs
//  three server-side fields that do not exist yet — category, rules and members-can-invite —
//  and shipping a wizard that silently discards two of its five steps would be worse than
//  shipping none. See the note on `CommunityDraftModel`.
//

import SwiftUI
import Combine

// MARK: - Draft

/// The community being built. `ObservableObject` rather than `@Observable`: every one of the
/// 48 stores in this app is the former, and a second observation system for one sheet is a
/// tax on whoever reads it next.
final class CommunityDraftModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case identity, privacy, spaces, rules, invite
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .identity: "Identity"
            case .privacy:  "Privacy"
            case .spaces:   "Spaces"
            case .rules:    "Rules"
            case .invite:   "Invite"
            }
        }

        var heading: String {
            switch self {
            case .identity: "What are you building?"
            case .privacy:  "Who can join?"
            case .spaces:   "What will people talk about?"
            case .rules:    "How should people behave?"
            case .invite:   "Who's coming with you?"
            }
        }

        var subheading: String {
            switch self {
            case .identity: "A name and a line about it. Everything else can change later."
            case .privacy:  "You can change this at any time."
            case .spaces:   "Spaces are channels. Start with a couple and add more later."
            case .rules:    "Suggested, not imposed. Edit or remove any of them."
            case .invite:   "Invite people now, or share a link once it exists."
            }
        }

        /// A community needs a name. It does not need the rest before it exists.
        var isSkippable: Bool { self != .identity }
    }

    @Published var name = ""
    @Published var about = ""
    @Published var category = "Design"
    @Published var joinPolicy = "approval"
    @Published var discoverable = true
    @Published var membersCanInvite = true
    @Published var spaceIDs: Set<String> = ["general", "announcements"]
    @Published var ruleIDs: Set<String> = ["respect", "promo", "onTopic"]

    /// Derived, not typed. A handle the user has to invent is a second naming decision for no
    /// gain, and it can be edited once the community exists.
    var handle: String {
        let base = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
        return String(base.prefix(20))
    }

    var canContinue: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct SpaceTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let icon: String

    static let all: [SpaceTemplate] = [
        .init(id: "announcements", name: "Announcements", detail: "Host posts, everyone reads.", icon: "megaphone.fill"),
        .init(id: "general",       name: "General",       detail: "The room everything starts in.", icon: "bubble.left.and.bubble.right.fill"),
        .init(id: "showcase",      name: "Showcase",      detail: "Finished work, shown off.", icon: "sparkles"),
        .init(id: "help",          name: "Help",          detail: "Questions, and people who answer them.", icon: "lifepreserver.fill"),
        .init(id: "offtopic",      name: "Off topic",     detail: "Everything that isn't the point.", icon: "cup.and.saucer.fill"),
        .init(id: "jobs",          name: "Jobs",          detail: "Who's hiring, who's looking.", icon: "briefcase.fill"),
    ]
}

struct RuleTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String

    static let all: [RuleTemplate] = [
        .init(id: "respect", title: "Be respectful", detail: "Critique the work, never the person."),
        .init(id: "promo",   title: "No unsolicited promotion", detail: "Ads and cold pitches belong elsewhere."),
        .init(id: "onTopic", title: "Keep it on topic", detail: "Post in the Space that fits what you're saying."),
        .init(id: "credit",  title: "Credit your sources", detail: "If it isn't yours, say whose it is and link it."),
        .init(id: "spam",    title: "No spam or repeat posting", detail: "Say it once, in one place."),
        .init(id: "privacy", title: "Respect privacy", detail: "Don't share anyone's details without their say-so."),
    ]
}

private struct PolicyOption: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String

    static let all: [PolicyOption] = [
        .init(id: "open", title: "Anyone can join", detail: "Open to everyone who finds it.", icon: "globe"),
        .init(id: "approval", title: "Approval needed", detail: "People ask, you decide.", icon: "checkmark.shield.fill"),
        .init(id: "invite_only", title: "Invite only", detail: "Only people with a link get in.", icon: "lock.fill"),
    ]
}

// MARK: - Flow

struct CommunityCreateFlow: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = CommunityDraftModel()
    @State private var step: CommunityDraftModel.Step = .identity

    /// Hands the finished draft back. The caller owns what happens next.
    var onCreate: (CommunityDraftModel) -> Void = { _ in }

    private var stepIndex: Int { step.rawValue }
    private var isLast: Bool { step == .invite }

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    progressBar

                    ScrollView {
                        VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                            heading

                            switch step {
                            case .identity: identityStep
                            case .privacy:  privacyStep
                            case .spaces:   spacesStep
                            case .rules:    rulesStep
                            case .invite:   inviteStep
                            }
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.top, VoiidSpacing.md)
                        .padding(.bottom, VoiidSpacing.xl)
                    }
                    .scrollIndicators(.hidden)

                    footer
                }
            }
            .navigationTitle("New Community")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { Haptics.tap(); dismiss() }
                        .tint(VoiidColor.textSecondary)
                }
            }
        }
    }

    // MARK: Progress

    /// Segments, not a continuous bar. Five discrete decisions read better as five marks — and
    /// a completed segment stays lit, so going back does not look like losing progress.
    private var progressBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(CommunityDraftModel.Step.allCases) { s in
                    Capsule()
                        .fill(s.rawValue <= stepIndex ? VoiidColor.accent : VoiidColor.divider)
                        .frame(height: 3)
                }
            }

            HStack {
                Text("Step \(stepIndex + 1) of \(CommunityDraftModel.Step.allCases.count)")
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)
                Spacer(minLength: 0)
                Text(step.title)
                    .font(VoiidFont.rounded(11.5, .semibold))
                    .foregroundColor(VoiidColor.accentInk)
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .animation(.easeOut(duration: 0.22), value: stepIndex)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(step.heading)
                .font(VoiidFont.rounded(23, .bold))
                .foregroundColor(VoiidColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(step.subheading)
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 1 — identity

    private var identityStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            VStack(spacing: VoiidSpacing.sm) {
                Circle()
                    .fill(VoiidColor.accentTint)
                    .frame(width: 78, height: 78)
                    .overlay(Circle().stroke(VoiidColor.accent.opacity(0.35), lineWidth: 1))
                    .overlay(
                        Text(initials.isEmpty ? "?" : initials)
                            .font(VoiidFont.rounded(26, .bold))
                            .foregroundColor(VoiidColor.accentInk)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11))
                            .foregroundColor(VoiidColor.textOnAccent)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(VoiidColor.accent))
                            .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2.5))
                    }

                Text("Add an icon")
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            .frame(maxWidth: .infinity)

            field("Community name") {
                TextField("Voiid Designers", text: $draft.name)
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
            }

            // Derived, not typed — a handle the user has to invent is a second naming decision
            // for no gain, and it can be edited after the community exists.
            if !draft.handle.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "at").font(.system(size: 10))
                    Text(draft.handle).font(VoiidFont.rounded(12.5, .medium))
                    Spacer(minLength: 0)
                    Text("Auto")
                        .font(VoiidFont.rounded(10, .bold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(VoiidColor.surfaceRaised))
                }
                .foregroundColor(VoiidColor.accentInk)
                .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 9)
                .background(VoiidColor.accentTint)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            field("What's it for?") {
                TextField("A community for designers to share, learn and grow together.",
                          text: $draft.about, axis: .vertical)
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
                    .lineLimit(3...6)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Category")
                    .font(VoiidFont.rounded(12.5, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["Design", "Tech", "Gaming", "Music", "Sport", "Local"], id: \.self) { option in
                            let selected = draft.category == option
                            Button {
                                Haptics.selection()
                                draft.category = option
                            } label: {
                                Text(option)
                                    .font(VoiidFont.rounded(13.5, .semibold))
                                    .foregroundColor(selected ? VoiidColor.textOnAccent : VoiidColor.textPrimary)
                                    .padding(.horizontal, 15)
                                    .frame(height: 36)
                                    .background(Capsule().fill(selected ? VoiidColor.accent : VoiidColor.surfaceCard))
                                    .overlay(Capsule().stroke(selected ? .clear : VoiidColor.divider, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    private var initials: String {
        let parts = draft.name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    // MARK: Step 2 — privacy

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            VStack(spacing: 8) {
                ForEach(PolicyOption.all) { policy in
                    let selected = draft.joinPolicy == policy.id
                    Button {
                        Haptics.selection()
                        withAnimation(.easeOut(duration: 0.18)) {
                            draft.joinPolicy = policy.id
                            // Invite-only where every member can invite is not invite-only.
                            // The dependent setting follows rather than silently contradicting.
                            if policy.id == "invite_only" { draft.membersCanInvite = false }
                        }
                    } label: {
                        HStack(spacing: VoiidSpacing.md) {
                            Image(systemName: policy.icon)
                                .font(.system(size: 16))
                                .foregroundColor(selected ? VoiidColor.accentInk : VoiidColor.textSecondary)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(policy.title)
                                    .font(VoiidFont.rounded(15, .semibold))
                                    .foregroundColor(VoiidColor.textPrimary)
                                Text(policy.detail)
                                    .font(VoiidFont.rounded(12.5))
                                    .foregroundColor(VoiidColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 21))
                                .foregroundStyle(selected ? VoiidColor.textOnAccent : VoiidColor.textSecondary,
                                                 selected ? VoiidColor.accent : .clear)
                        }
                        .padding(VoiidSpacing.md - 2)
                        .background(selected ? VoiidColor.accentTint : VoiidColor.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                            .stroke(selected ? VoiidColor.accent : VoiidColor.divider,
                                    lineWidth: selected ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }

            toggleRow("Show in search",
                      detail: "People can find it without a link.",
                      isOn: $draft.discoverable)

            toggleRow("Members can invite",
                      detail: draft.joinPolicy == "invite_only"
                              ? "Turned off — invite-only means only you invite."
                              : "Anyone inside can bring someone in.",
                      isOn: $draft.membersCanInvite)
                .disabled(draft.joinPolicy == "invite_only")
                .opacity(draft.joinPolicy == "invite_only" ? 0.5 : 1)
        }
    }

    // MARK: Step 3 — spaces

    private var spacesStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SpaceTemplate.all) { space in
                let on = draft.spaceIDs.contains(space.id)
                Button {
                    Haptics.selection()
                    withAnimation(.easeOut(duration: 0.15)) {
                        if on { draft.spaceIDs.remove(space.id) } else { draft.spaceIDs.insert(space.id) }
                    }
                } label: {
                    selectableRow(icon: space.icon, title: space.name,
                                  detail: space.detail, selected: on)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Step 4 — rules

    private var rulesStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(RuleTemplate.all) { rule in
                let on = draft.ruleIDs.contains(rule.id)
                Button {
                    Haptics.selection()
                    withAnimation(.easeOut(duration: 0.15)) {
                        if on { draft.ruleIDs.remove(rule.id) } else { draft.ruleIDs.insert(rule.id) }
                    }
                } label: {
                    selectableRow(icon: "checkmark.seal", title: rule.title,
                                  detail: rule.detail, selected: on)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Step 5 — invite

    private var inviteStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                HStack(spacing: VoiidSpacing.sm) {
                    Image(systemName: "link")
                        .font(.system(size: 15))
                        .foregroundColor(VoiidColor.textOnAccent)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(VoiidColor.accent))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Share a link")
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                        Text("Once it exists you get a link anyone can open.")
                            .font(VoiidFont.rounded(12.5))
                            .foregroundColor(VoiidColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(VoiidSpacing.md - 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VoiidColor.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(VoiidColor.divider, lineWidth: 1))
            }

            summary
        }
    }

    /// The last step is also the review. Five decisions restated in one place beats a separate
    /// confirmation screen that repeats them.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review")
                .font(VoiidFont.rounded(12.5, .semibold))
                .foregroundColor(VoiidColor.textSecondary)

            summaryRow("Name", draft.name.isEmpty ? "—" : draft.name)
            summaryRow("Handle", draft.handle.isEmpty ? "—" : "@\(draft.handle)")
            summaryRow("Category", draft.category)
            summaryRow("Joining", PolicyOption.all.first { $0.id == draft.joinPolicy }?.title ?? "—")
            summaryRow("In search", draft.discoverable ? "Yes" : "No")
            summaryRow("Spaces", "\(draft.spaceIDs.count)")
            summaryRow("Rules", "\(draft.ruleIDs.count)")
        }
        .padding(VoiidSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
            Spacer(minLength: VoiidSpacing.md)
            Text(value)
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: VoiidSpacing.sm) {
            if stepIndex > 0 {
                Button {
                    Haptics.tap()
                    withAnimation(.easeOut(duration: 0.2)) {
                        step = CommunityDraftModel.Step(rawValue: stepIndex - 1) ?? .identity
                    }
                } label: {
                    Text("Back")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(width: 88, height: 46)
                        .background(Capsule().fill(VoiidColor.surfaceCard))
                        .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            Button {
                Haptics.tap()
                if isLast {
                    onCreate(draft)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        step = CommunityDraftModel.Step(rawValue: stepIndex + 1) ?? .invite
                    }
                }
            } label: {
                Text(isLast ? "Create community" : "Continue")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Capsule().fill(draft.canContinue ? VoiidColor.accent
                                                                 : VoiidColor.placeholder))
            }
            .buttonStyle(.plain)
            .disabled(!draft.canContinue)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .padding(.bottom, VoiidSpacing.sm)
        .background(.ultraThinMaterial)
        .overlay(Divider().background(VoiidColor.divider), alignment: .top)
    }

    // MARK: Pieces

    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(VoiidFont.rounded(12.5, .semibold))
                .foregroundColor(VoiidColor.textSecondary)
            content()
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 12)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(VoiidColor.fieldBorder, lineWidth: 1))
        }
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text(detail)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(VoiidColor.accent)
        }
        .padding(VoiidSpacing.md - 2)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }

    private func selectableRow(icon: String, title: String,
                               detail: String, selected: Bool) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(selected ? VoiidColor.accentInk : VoiidColor.textSecondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text(detail)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 21))
                .foregroundStyle(selected ? VoiidColor.textOnAccent : VoiidColor.textSecondary,
                                 selected ? VoiidColor.accent : .clear)
        }
        .padding(VoiidSpacing.md - 2)
        .background(selected ? VoiidColor.accentTint : VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(selected ? VoiidColor.accent : VoiidColor.divider,
                    lineWidth: selected ? 1.5 : 1))
    }
}

#Preview { CommunityCreateFlow() }

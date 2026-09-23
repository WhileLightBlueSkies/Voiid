//
//  CommunitySetupCard.swift
//  Voiid
//
//  "Finish setting up" — what the two-step create flow deliberately did not ask.
//
//  ── DERIVED FROM THE SERVER, NOT REMEMBERED ─────────────────────────────────────
//  Each task is done when the community SAYS it is done: a description exists, a Space beyond
//  the two every community gets exists, a rule exists, an invite exists or someone else has
//  joined. Nothing is stored about the checklist itself, so it is right on every device and on
//  Android, and a host who wrote rules from settings instead of from here sees them ticked.
//
//  The one local fact is "Hide": a host who does not want the card can dismiss it for this
//  community on this device. Hiding a suggestion is a preference, not community state.
//
//  ── OWNER ONLY ──────────────────────────────────────────────────────────────────
//  These are the owner's decisions to make about what the community is. The caller only draws
//  this for the owner; every write behind it is gated by the server regardless.
//

import SwiftUI

struct CommunitySetupCard: View {
    let card: CommunityService.CommunityCard
    /// The description was written here — hand the updated card up so the page redraws.
    var onUpdated: (CommunityService.CommunityCard) -> Void
    var onAddSpaces: () -> Void
    var onSetRules: () -> Void
    var onInvite: () -> Void

    enum Item: String, CaseIterable, Identifiable {
        case describe, spaces, rules, invite
        var id: String { rawValue }

        var title: String {
            switch self {
            case .describe: "Say what it\u{2019}s for"
            case .spaces:   "Add your first Spaces"
            case .rules:    "Set a few ground rules"
            case .invite:   "Invite your first members"
            }
        }

        var icon: String {
            switch self {
            case .describe: "text.alignleft"
            case .spaces:   "square.grid.2x2.fill"
            case .rules:    "list.bullet.rectangle.fill"
            case .invite:   "person.badge.plus"
            }
        }
    }

    /// Nil until the first load finishes — so the card never flashes four undone tasks at a
    /// host who has done three of them.
    @State private var done: Set<Item>?
    @State private var describing = false
    @AppStorage private var hidden: Bool

    init(card: CommunityService.CommunityCard,
         onUpdated: @escaping (CommunityService.CommunityCard) -> Void,
         onAddSpaces: @escaping () -> Void,
         onSetRules: @escaping () -> Void,
         onInvite: @escaping () -> Void) {
        self.card = card
        self.onUpdated = onUpdated
        self.onAddSpaces = onAddSpaces
        self.onSetRules = onSetRules
        self.onInvite = onInvite
        _hidden = AppStorage(wrappedValue: false, "communitySetupHidden.\(card.id)")
    }

    private var remaining: [Item] {
        guard let done else { return [] }
        return Item.allCases.filter { !done.contains($0) }
    }

    /// What should re-run the check. The card reloads every 10 s behind this view; only a change
    /// that could tick a task needs another round of requests.
    private var reloadKey: String {
        "\(card.id)|\(card.description ?? "")|\(card.member_count ?? 0)"
    }

    var body: some View {
        Group {
            if !hidden, !remaining.isEmpty {
                content
            }
        }
        .task(id: reloadKey) { await load() }
        .sheet(isPresented: $describing, onDismiss: { Task { await load() } }) {
            DescribeCommunitySheet(card: card) { updated in
                onUpdated(updated)
            }
        }
    }

    private var content: some View {
        let total = Item.allCases.count
        let doneCount = total - remaining.count
        return VStack(alignment: .leading, spacing: VoiidSpacing.sm + 2) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish setting up")
                        .font(VoiidFont.rounded(16, .bold))
                        .foregroundColor(VoiidColor.textPrimary)
                    Text("Your community is live. These make it feel lived in.")
                        .font(VoiidFont.rounded(12.5))
                        .foregroundColor(VoiidColor.textSecondary)
                }
                Spacer(minLength: 0)
                Text("\(doneCount)/\(total)")
                    .font(VoiidFont.rounded(12.5, .bold))
                    .foregroundColor(VoiidColor.accentInk)
                    .monospacedDigit()
                Menu {
                    Button("Hide this card", systemImage: "eye.slash") {
                        Haptics.tap()
                        withAnimation(.easeOut(duration: 0.2)) { hidden = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .frame(width: 30, height: 24)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Setup card options")
            }

            ProgressView(value: Double(doneCount), total: Double(total))
                .tint(VoiidColor.accent)

            VStack(spacing: 0) {
                ForEach(remaining) { task in
                    Button {
                        Haptics.tap()
                        run(task)
                    } label: {
                        HStack(spacing: VoiidSpacing.sm + 2) {
                            Image(systemName: task.icon)
                                .font(.system(size: 13))
                                .foregroundColor(VoiidColor.accentInk)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(VoiidColor.accentTint))
                            Text(task.title)
                                .font(VoiidFont.rounded(14.5, .semibold))
                                .foregroundColor(VoiidColor.textPrimary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(VoiidColor.textSecondary)
                        }
                        .frame(height: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if task != remaining.last {
                        Divider().overlay(VoiidColor.divider).padding(.leading, 40)
                    }
                }
            }
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.accent.opacity(0.35), lineWidth: 1))
        .transition(.opacity)
    }

    /// Each row DOES its task, or opens the one screen that does. A row that only described it
    /// would send the host off to find the right place themselves.
    private func run(_ task: Item) {
        switch task {
        case .describe: describing = true
        case .spaces:   onAddSpaces()
        case .rules:    onSetRules()
        case .invite:   onInvite()
        }
    }

    /// Three reads, in parallel. A read that fails counts its task as done rather than undone:
    /// nagging a host to do something they may already have done is worse than a missed nudge.
    private func load() async {
        let id = card.id
        async let channels = try? CommunityService.shared.channels(communityId: id)
        async let rules = try? CommunityService.shared.rules(communityId: id)
        async let invites = try? CommunityService.shared.invites(communityId: id)
        let (c, r, i) = await (channels, rules, invites)

        var result: Set<Item> = []
        if !(card.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.insert(.describe)
        }
        // Announcements and General come with every community; a third is the host's own.
        if (c.map { $0.count > 2 }) ?? true { result.insert(.spaces) }
        if (r.map { !$0.isEmpty }) ?? true { result.insert(.rules) }
        if (card.member_count ?? 0) > 1 || ((i.map { !$0.isEmpty }) ?? true) {
            result.insert(.invite)
        }
        withAnimation(.easeOut(duration: 0.2)) { done = result }
    }
}

// MARK: - Describe

/// The one setup task that is just a sentence, so it gets a sentence-sized sheet rather than a
/// trip to settings.
private struct DescribeCommunitySheet: View {
    let card: CommunityService.CommunityCard
    var onSaved: (CommunityService.CommunityCard) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var about = ""
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    /// MAX_DESCRIPTION in the route.
    private let limit = 500

    private var trimmed: String { about.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                Text("One or two sentences. It\u{2019}s the first thing people read before they join.")
                    .font(VoiidFont.rounded(13.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("A place for…", text: $about, axis: .vertical)
                    .font(VoiidFont.rounded(16))
                    .lineLimit(3...6)
                    .focused($focused)
                    .padding(VoiidSpacing.md)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                        .stroke(VoiidColor.fieldBorder, lineWidth: 1))
                    .onChange(of: about) { _, v in if v.count > limit { about = String(v.prefix(limit)) } }

                if let failure {
                    Label(failure, systemImage: "exclamationmark.circle.fill")
                        .font(VoiidFont.rounded(12.5))
                        .foregroundColor(VoiidColor.error)
                }
                Spacer(minLength: 0)
            }
            .padding(VoiidSpacing.md)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("What\u{2019}s it for?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(trimmed.isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        saving = true
        failure = nil
        defer { saving = false }
        do {
            let updated = try await CommunityService.shared.update(communityId: card.id,
                                                                   description: .some(trimmed))
            Haptics.success()
            onSaved(updated)
            dismiss()
        } catch {
            Haptics.error()
            failure = (error as? APIError)?.errorDescription ?? "Couldn\u{2019}t save that."
        }
    }
}

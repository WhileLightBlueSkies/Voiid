//
//  MomentsPrivacyView.swift
//  Voiid
//
//  One place for who sees your moments, instead of a picker on every post.
//
//  ── ONE SETTING, SHOWN WHERE YOU POST ───────────────────────────────────────────
//  Who your moments go to is chosen here once — all your connections, only your phone
//  contacts, only people you chat with, only people you pick, or nobody — and every new moment
//  follows it. The composer shows the current choice and opens this screen, so it is visible at
//  the moment it matters and changed in one place. "Hide from" leaves particular people out of
//  the three group choices.
//
//  ── WHAT A CHANGE DOES ──────────────────────────────────────────────────────────
//  It applies to NEW moments. One already shared was encrypted for the people it went to; it
//  cannot be taken back from them, and the footer says so rather than implying it.
//
//  Reached from the gear on the Moments tab (Moments settings), Settings → Privacy → Moments,
//  and the composer.
//

import SwiftUI

struct MomentsPrivacyView: View {
    @ObservedObject private var settings = StorySettings.shared
    @State private var picking: PeoplePick?

    private enum PeoplePick: String, Identifiable {
        case selected, hidden
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VoiidSettingsHeader("Moments settings",
                                    subtitle: "Choose who sees the moments you share, and what's kept.",
                                    badge: (icon: "lock.fill", text: "End-to-end encrypted"))

                audienceSection

                if settings.audienceMode.allowsHiding {
                    hideSection
                        .transition(.opacity)
                }

                viewingSection

                VoiidCardSection {
                    NavigationLink { StoryArchiveView() } label: {
                        VoiidSettingsRow(icon: "archivebox", title: "Archive",
                                         detail: "Your moments kept after 24 hours") {
                            VoiidChevron()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(VoiidSpacing.md)
            .animation(.easeOut(duration: 0.2), value: settings.audienceMode)
        }
        .font(.body)
        .foregroundStyle(VoiidColor.textPrimary)
        .fontDesign(.rounded)
        .voiidSettingsPage()
        .navigationTitle("Moments settings")
        .sheet(item: $picking) { pick in
            switch pick {
            case .selected:
                MomentsPeoplePicker(title: "Share with",
                                    prompt: "Only these people will see your moments.",
                                    candidates: UserDirectory.shared.storyReachableUserIds(),
                                    selection: $settings.selectedPeople)
            case .hidden:
                MomentsPeoplePicker(title: "Hide from",
                                    prompt: "These people won't see your moments.",
                                    candidates: settings.people(for: settings.audienceMode),
                                    selection: $settings.hiddenFrom)
            }
        }
    }

    // MARK: Who

    private var audienceSection: some View {
        VoiidCardSection("Who can see my moments",
                         footer: "Changes apply to new moments. A moment you've already shared stays with the people it was sent to. Voiid can't see your moments, but it does see who they're sent to.") {
            ForEach(Array(MomentAudience.allCases.enumerated()), id: \.element) { index, mode in
                if index > 0 { VoiidRowDivider() }
                audienceRow(mode)
            }
        }
    }

    private func audienceRow(_ mode: MomentAudience) -> some View {
        let on = settings.audienceMode == mode
        return VoiidSettingsRow(icon: mode.icon, title: mode.title, detail: detail(for: mode), action: {
            if mode == .selected {
                // Choosing it opens the list: an empty "selected" would send to no one.
                if !on { Haptics.selection() }
                settings.audienceMode = .selected
                if settings.selectedPeople.isEmpty || on { picking = .selected }
                return
            }
            guard !on else { return }
            Haptics.selection()
            settings.audienceMode = mode
        }) {
            HStack(spacing: 8) {
                if mode != .nobody {
                    Text("\(count(for: mode))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VoiidColor.accent)
                    .opacity(on ? 1 : 0)
            }
        }
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func detail(for mode: MomentAudience) -> String {
        if mode == .selected, !settings.selectedPeople.isEmpty {
            return "\(settings.selectedPeople.count) \(settings.selectedPeople.count == 1 ? "person" : "people") · Tap to change"
        }
        return mode.detail
    }

    /// How many people the choice reaches right now, after "Hide from".
    private func count(for mode: MomentAudience) -> Int {
        var ids = settings.people(for: mode)
        if mode.allowsHiding { ids.subtract(settings.hiddenFrom) }
        return ids.count
    }

    // MARK: Hide from

    private var hideSection: some View {
        let hidden = settings.hiddenFrom.intersection(settings.people(for: settings.audienceMode)).count
        return VoiidCardSection(footer: "People you hide won't get your new moments, and aren't told.") {
            VoiidSettingsRow(icon: "eye.slash", title: "Hide from",
                             detail: hidden == 0 ? "No one hidden" : "\(hidden) \(hidden == 1 ? "person" : "people") hidden",
                             action: { picking = .hidden }) {
                VoiidChevron()
            }
        }
    }

    // MARK: Viewing

    private var viewingSection: some View {
        VoiidCardSection("Viewing",
                         footer: "View receipts work both ways: turn them off to hide your views and stop seeing who viewed yours. Keep my moments saves your own moments on this phone after 24 hours.") {
            VoiidSettingsRow(icon: "eye.circle", title: "Moment view receipts") {
                Toggle("Moment view receipts", isOn: $settings.sendViewReceipts)
                    .labelsHidden()
                    .tint(VoiidColor.primary)
            }
            VoiidRowDivider()
            VoiidSettingsRow(icon: "archivebox", title: "Keep my moments") {
                Toggle("Keep my moments", isOn: $settings.archiveByDefault)
                    .labelsHidden()
                    .tint(VoiidColor.primary)
            }
        }
    }
}

// MARK: - People picker

/// A searchable list of people with checkmarks, for "Share with" and "Hide from".
struct MomentsPeoplePicker: View {
    let title: String
    let prompt: String
    let candidates: Set<String>
    @Binding var selection: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Edited here and committed on Done, so Cancel really cancels.
    @State private var draft: Set<String> = []

    private struct Person: Identifiable {
        let id: String
        let name: String
        let photoURL: String?
    }

    private var people: [Person] {
        let all = candidates.map {
            Person(id: $0, name: UserDirectory.shared.displayName($0), photoURL: UserDirectory.shared.photoURL($0))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if candidates.isEmpty {
                        Text("No one here yet. People you add in Contacts or chat with will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(VoiidColor.textSecondary)
                            .listRowBackground(VoiidColor.surfaceCard)
                    }
                    ForEach(people) { person in
                        let on = draft.contains(person.id)
                        Button {
                            Haptics.selection()
                            if on { draft.remove(person.id) } else { draft.insert(person.id) }
                        } label: {
                            HStack(spacing: VoiidSpacing.md) {
                                ProfileAvatarButton(photoURL: person.photoURL, name: person.name, size: 38)
                                Text(person.name)
                                    .foregroundStyle(VoiidColor.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22))
                                    .foregroundStyle(on ? VoiidColor.primary : VoiidColor.placeholder)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(VoiidColor.surfaceCard)
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                } footer: {
                    Text(prompt).font(.footnote).foregroundStyle(VoiidColor.textSecondary)
                }
            }
            .voiidSettingsList()
            .background(VoiidColor.background.ignoresSafeArea())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .navigationTitle(draft.isEmpty ? title : "\(title) (\(draft.count))")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selection = draft
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear { draft = selection }
    }
}

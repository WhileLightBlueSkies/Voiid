//
//  CommunityCreateFlow.swift
//  Voiid
//
//  Creating a community — two steps. Ported from the reference's CreateCommunityFlow.
//
//  ── WHAT IT IS, THEN WHO GETS IN ────────────────────────────────────────────────
//  Step 1 is identity: an icon, a name and a category (only the name is required).
//  Step 2 is who can join. That one is asked up front, unlike the rest, because it is the
//  decision that is costly to get wrong later: a community created open has already let
//  people in by the time its host finds the setting.
//
//  Everything else the old five-step wizard asked for — description, extra Spaces, rules,
//  invites — is left out. The server gives every community Announcements and General, and the
//  rest comes back as the "Finish setting up" card on the community's Home
//  (`CommunitySetupCard`), where it is easier to decide with the community in front of you.
//
//  ── ONE SHEET, CONTENT SWAPS ────────────────────────────────────────────────────
//  Not a pushed screen per step: the footer stays put, and the leading button means Cancel on
//  step 1 and Back on step 2 — never "throw away what I typed" by surprise.
//
//  ── THE HANDLE IS SHOWN, NOT HIDDEN ─────────────────────────────────────────────
//  It is derived from the name, so a host is not asked to invent a second name — but it is the
//  community's address, and it shares one namespace with every username and social handle on
//  Voiid. So it is visible, editable in place, and checked against the server as it changes
//  (`GET /communities/handle-available`), rather than failing with a 409 on the last tap.
//

import PhotosUI
import SwiftUI

// MARK: - Handle

/// A community's handle — the `voiid.app/c/<handle>` address.
///
/// The FORMAT rules are the server's, copied exactly: `HANDLE_RE` in backend/api/src/routes/
/// communities.ts is `^[a-z][a-z0-9_]{2,19}$`. Whether a valid handle is FREE only the server
/// can say; see `CommunityService.handleAvailable`.
enum CommunityHandle {
    static let maxLength = 20

    /// A valid handle made from the name, or "" when the name has nothing usable in it (a name
    /// written entirely in Devanagari, say) — the host then picks one themselves.
    static func suggest(from name: String) -> String {
        // "Café Noir" → "cafenoir": fold accents rather than drop the letters.
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        var handle = String(folded.unicodeScalars
            .filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            .map(Character.init))
        // Must start with a letter: "2026 Batch" → "batch2026", not a rejected "2026batch".
        let leadingDigits = handle.prefix { $0.isNumber }
        handle = String(handle.dropFirst(leadingDigits.count)) + leadingDigits
        guard handle.first?.isLetter == true else { return "" }
        // Too short to be valid: "AI" → "aicommunity".
        if handle.count < 3 { handle += "community" }
        return String(handle.prefix(maxLength))
    }

    /// `base` with a number on the end that still fits: `designdaily` → `designdaily2`.
    static func numbered(_ base: String, _ n: Int) -> String {
        let suffix = String(n)
        return String(base.prefix(maxLength - suffix.count)) + suffix
    }

    /// What typing into the handle field keeps: lowercase letters, digits and underscores.
    static func sanitise(_ typed: String) -> String {
        String(typed.lowercased().unicodeScalars
            .filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
            .map(Character.init)
            .prefix(maxLength))
    }

    /// Why a handle's FORMAT is wrong, in words a host can act on, or nil if it is fine.
    static func formatProblem(_ handle: String) -> String? {
        if handle.isEmpty { return "Pick an address for your community." }
        if handle.first?.isLetter != true { return "Start the address with a letter." }
        if handle.count < 3 { return "Use at least 3 characters." }
        return nil
    }
}

// MARK: - Category

/// The categories offered at creation and in settings — one list, so a host never sees one set
/// when creating and a different set when editing.
///
/// The column is FREE TEXT and the server accepts any string, so this is a convenience and not
/// a validation: a community whose category came from an older build keeps it.
enum CommunityCategory {
    static let all = ["Education", "Design", "Tech", "Gaming", "Music", "Sport", "Local", "Business"]

    static func icon(_ category: String) -> String {
        switch category {
        case "Education": "graduationcap.fill"
        case "Design":    "paintpalette.fill"
        case "Tech":      "chevron.left.forwardslash.chevron.right"
        case "Gaming":    "gamecontroller.fill"
        case "Music":     "music.note"
        case "Sport":     "figure.run"
        case "Local":     "mappin.and.ellipse"
        case "Business":  "briefcase.fill"
        default:          "circle.grid.2x2.fill"
        }
    }
}

// MARK: - Flow

struct CommunityCreateFlow: View {
    @Environment(\.dismiss) private var dismiss

    /// Hands back the community the SERVER created — the caller needs the id and handle, and
    /// only the server knows them.
    var onCreate: (CommunityService.CommunityCard) -> Void = { _ in }

    private enum Step: Int { case identity = 1, joining = 2 }

    /// Where the handle check stands. `.unknown` after a network failure: the create route is
    /// the real check, so a failed ADVISORY call must not block the host.
    private enum Availability: Equatable { case checking, available, taken, unknown }

    @State private var step: Step = .identity
    @State private var name = ""
    @State private var category = ""
    /// "open" by default — the least friction for a community that is just starting, and the
    /// first option on the step, so Create without a choice does what the screen shows.
    @State private var joinPolicy = "open"

    @State private var pickedPhoto: PhotosPickerItem?
    @State private var icon: UIImage?

    /// Nil while the handle follows the name. Set the moment the host edits it; from then on
    /// retyping the name must not undo a choice they made.
    @State private var customHandle: String?
    /// The derived handle after stepping past taken ones (`designdaily` → `designdaily2`).
    /// The host SEES the number before creating and can change it.
    @State private var resolvedSuggestion = ""
    @State private var availability: Availability = .checking

    @State private var creating = false
    @State private var createError: String?

    @FocusState private var nameFocused: Bool
    @FocusState private var handleFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var suggestion: String { CommunityHandle.suggest(from: name) }
    private var handle: String { customHandle ?? (resolvedSuggestion.isEmpty ? suggestion : resolvedSuggestion) }

    private var handleProblem: String? {
        if let problem = CommunityHandle.formatProblem(handle) { return problem }
        return availability == .taken ? "That address is taken. Try another." : nil
    }

    /// Only speak up once there is something to be wrong about — not over an empty form.
    private var showsHandleProblem: Bool {
        handleProblem != nil && (customHandle != nil || !trimmedName.isEmpty)
    }

    private var canContinue: Bool {
        !trimmedName.isEmpty && handleProblem == nil && availability != .checking
    }

    /// Everything that should re-run the availability check when it changes.
    private struct HandleQuery: Equatable { let suggestion: String; let custom: String? }

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                        switch step {
                        case .identity:
                            identityHeading
                            identityCard
                            categoryPicker
                        case .joining:
                            joiningHeading
                            joinOptions
                            laterNote
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.top, VoiidSpacing.md)
                    .padding(.bottom, VoiidSpacing.xl)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("New community")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step == .identity {
                        Button("Cancel") { Haptics.tap(); dismiss() }
                            .tint(VoiidColor.textSecondary)
                    } else {
                        Button {
                            Haptics.tap()
                            createError = nil
                            withAnimation(.easeOut(duration: 0.2)) { step = .identity }
                        } label: {
                            Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                        }
                        .tint(VoiidColor.textSecondary)
                        .disabled(creating)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(step.rawValue) of 2")
                        .font(VoiidFont.rounded(12.5, .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .monospacedDigit()
                        .accessibilityLabel("Step \(step.rawValue) of 2")
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
            // Swiping the sheet away on step 2 would lose step 1 without a word.
            .interactiveDismissDisabled(step == .joining || creating)
            .onAppear { nameFocused = true }
            .onChange(of: pickedPhoto) { _, item in
                Task {
                    guard let item, let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    icon = image
                }
            }
            .task(id: HandleQuery(suggestion: suggestion, custom: customHandle)) {
                await checkHandle()
            }
        }
    }

    // MARK: Step 1 — identity

    private var identityHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bring your people together")
                .font(VoiidFont.rounded(24, .bold))
                .foregroundColor(VoiidColor.textPrimary)
            Text("Start with a name. You can add a description, Spaces and rules once it's live.")
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var identityCard: some View {
        VStack(spacing: VoiidSpacing.md) {
            iconPicker
            nameField
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }

    private var iconPicker: some View {
        PhotosPicker(selection: $pickedPhoto, matching: .images) {
            VStack(spacing: VoiidSpacing.sm) {
                iconView(size: 84)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: icon == nil ? "camera.fill" : "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(VoiidColor.textOnAccent)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(VoiidColor.accent))
                            .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2.5))
                    }
                Text(icon == nil ? "Add an icon" : "Change icon")
                    .font(VoiidFont.rounded(12.5, .semibold))
                    .foregroundColor(VoiidColor.accentInk)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(creating)
        .accessibilityLabel(icon == nil ? "Add a community icon" : "Change community icon")
    }

    @ViewBuilder
    private func iconView(size: CGFloat) -> some View {
        Group {
            if let icon {
                Image(uiImage: icon).resizable().scaledToFill()
            } else if trimmedName.isEmpty {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundColor(VoiidColor.accentInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(VoiidColor.accentTint)
            } else {
                Text(initials)
                    .font(VoiidFont.rounded(size * 0.33, .bold))
                    .foregroundColor(VoiidColor.accentInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(VoiidColor.accentTint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(VoiidColor.accent.opacity(0.35), lineWidth: 1))
    }

    private var initials: String {
        let parts = trimmedName.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first(where: \.isLetter) }.map(String.init).joined().uppercased()
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Community name")
                .font(VoiidFont.rounded(12.5, .semibold))
                .foregroundColor(VoiidColor.textSecondary)

            TextField("Northstar Photography Club", text: $name)
                .font(VoiidFont.rounded(16))
                .foregroundColor(VoiidColor.textPrimary)
                .tint(VoiidColor.accent)
                .focused($nameFocused)
                .submitLabel(.done)
                .padding(.horizontal, VoiidSpacing.md)
                .frame(height: 50)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(nameFocused ? VoiidColor.accent.opacity(0.6) : VoiidColor.fieldBorder,
                            lineWidth: 1))

            handleRow
        }
    }

    // MARK: Handle

    @ViewBuilder
    private var handleRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            if customHandle == nil {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .semibold))
                    Text("voiid.app/c/\(handle.isEmpty ? "…" : handle)")
                        .font(VoiidFont.rounded(12))
                        .lineLimit(1)
                    if availability == .checking, !handle.isEmpty {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                    Button("Edit") {
                        Haptics.tap()
                        customHandle = handle
                        handleFocused = true
                    }
                    .font(VoiidFont.rounded(12, .semibold))
                    .foregroundColor(VoiidColor.accentInk)
                    .accessibilityLabel("Edit community address")
                }
                .foregroundColor(canContinue ? VoiidColor.accentInk : VoiidColor.textSecondary)
                .padding(.leading, 4)
            } else {
                HStack(spacing: 0) {
                    Text("voiid.app/c/")
                        .font(VoiidFont.rounded(14))
                        .foregroundColor(VoiidColor.textSecondary)
                    TextField("yourcommunity", text: Binding(
                        get: { customHandle ?? "" },
                        set: { customHandle = CommunityHandle.sanitise($0) }))
                        .font(VoiidFont.rounded(14, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .tint(VoiidColor.accent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .focused($handleFocused)
                        .submitLabel(.done)
                    if availability == .checking, CommunityHandle.formatProblem(handle) == nil {
                        ProgressView().controlSize(.mini).padding(.trailing, 6)
                    } else if availability == .available, handleProblem == nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(VoiidColor.success)
                            .padding(.trailing, 6)
                            .accessibilityLabel("Address available")
                    }
                    Text("\(handle.count)/\(CommunityHandle.maxLength)")
                        .font(VoiidFont.rounded(11))
                        .foregroundColor(VoiidColor.textSecondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, VoiidSpacing.sm + 2)
                .frame(height: 42)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(showsHandleProblem ? VoiidColor.error.opacity(0.7)
                            : handleFocused ? VoiidColor.accent.opacity(0.6) : VoiidColor.fieldBorder,
                            lineWidth: 1))
            }

            if showsHandleProblem, let handleProblem {
                // Icon AND words, never colour alone.
                Label(handleProblem, systemImage: "exclamationmark.circle.fill")
                    .font(VoiidFont.rounded(12))
                    .foregroundColor(VoiidColor.error)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsHandleProblem)
        .animation(.easeOut(duration: 0.15), value: customHandle == nil)
    }

    /// Debounced, and cancelled by the next keystroke — `.task(id:)` cancels the previous run.
    ///
    /// While the handle follows the name, a taken suggestion is stepped past (`name2`, `name3`
    /// …) so the host lands on a free one without having to think about it. A handle they typed
    /// is only checked, never rewritten.
    private func checkHandle() async {
        availability = .checking
        // Drop the last resolved suggestion at once, so the row shows the new name's handle
        // rather than the previous name's while the check runs.
        if customHandle == nil { resolvedSuggestion = "" }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }

        if let custom = customHandle {
            guard CommunityHandle.formatProblem(custom) == nil else { availability = .unknown; return }
            availability = await isFree(custom)
            return
        }

        let base = suggestion
        guard CommunityHandle.formatProblem(base) == nil else {
            resolvedSuggestion = ""
            availability = .unknown
            return
        }
        for candidate in [base] + (2...5).map({ CommunityHandle.numbered(base, $0) }) {
            let result = await isFree(candidate)
            if Task.isCancelled { return }
            if result != .taken {
                resolvedSuggestion = candidate
                availability = result
                return
            }
        }
        // Five in a row taken: stop guessing and say so. The host can edit it.
        resolvedSuggestion = base
        availability = .taken
    }

    private func isFree(_ candidate: String) async -> Availability {
        do {
            return try await CommunityService.shared.handleAvailable(candidate).available ? .available : .taken
        } catch {
            return .unknown
        }
    }

    // MARK: Category

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("Category")
                    .font(VoiidFont.rounded(12.5, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
                Text("Optional")
                    .font(VoiidFont.rounded(11))
                    .foregroundColor(VoiidColor.textSecondary.opacity(0.8))
            }

            ChipFlowLayout(spacing: 8) {
                ForEach(CommunityCategory.all, id: \.self) { option in
                    let selected = category == option
                    Button {
                        Haptics.selection()
                        // Tapping the chosen one again clears it — optional means undoable.
                        category = selected ? "" : option
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: CommunityCategory.icon(option))
                                .font(.system(size: 12, weight: .semibold))
                            Text(option)
                                .font(VoiidFont.rounded(13.5, .semibold))
                        }
                        .foregroundColor(selected ? VoiidColor.textOnAccent : VoiidColor.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Capsule().fill(selected ? VoiidColor.accent : VoiidColor.surfaceCard))
                        .overlay(Capsule().stroke(selected ? .clear : VoiidColor.divider, lineWidth: 1))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
        }
    }

    // MARK: Step 2 — who can join

    private var joiningHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: VoiidSpacing.sm) {
                iconView(size: 36)
                Text(trimmedName)
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
                    .lineLimit(1)
            }
            .padding(.bottom, 4)

            Text("Who can join?")
                .font(VoiidFont.rounded(24, .bold))
                .foregroundColor(VoiidColor.textPrimary)
            Text("You can change this any time in settings.")
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textSecondary)
        }
    }

    /// The same options, in the same words, as the settings screen — `JoinPolicyOption` is the
    /// single source of that copy. The unavailable paid tier is left out here: creation is not
    /// the place to show a door that does not open yet.
    private var joinOptions: some View {
        VStack(spacing: 10) {
            ForEach(JoinPolicyOption.all.filter(\.available)) { policy in
                let selected = joinPolicy == policy.id
                Button {
                    Haptics.selection()
                    joinPolicy = policy.id
                } label: {
                    HStack(spacing: VoiidSpacing.sm + 4) {
                        Image(systemName: policy.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(selected ? VoiidColor.textOnAccent : VoiidColor.accentInk)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(selected ? VoiidColor.accent : VoiidColor.accentTint))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(policy.label)
                                .font(VoiidFont.rounded(15.5, .semibold))
                                .foregroundColor(VoiidColor.textPrimary)
                            Text(policy.explanation)
                                .font(VoiidFont.rounded(13))
                                .foregroundColor(VoiidColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 21))
                            .foregroundColor(selected ? VoiidColor.accentInk : VoiidColor.divider)
                    }
                    .padding(VoiidSpacing.md)
                    .background(VoiidColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                        .stroke(selected ? VoiidColor.accent : VoiidColor.divider,
                                lineWidth: selected ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(creating)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    private var laterNote: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(VoiidColor.accentInk)
            VStack(alignment: .leading, spacing: 3) {
                Text("You can finish the details later")
                    .font(VoiidFont.rounded(13.5, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text("Your community is ready after this. Add a description, Spaces, rules and invites from its Home whenever you like.")
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(VoiidSpacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.accentTint.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: VoiidSpacing.xs) {
            if let createError {
                Text(createError)
                    .font(VoiidFont.footnote)
                    .foregroundColor(VoiidColor.error)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            Button {
                if step == .identity {
                    Haptics.tap()
                    nameFocused = false
                    handleFocused = false
                    withAnimation(.easeOut(duration: 0.2)) { step = .joining }
                } else {
                    Task { await create() }
                }
            } label: {
                Group {
                    if creating {
                        ProgressView().tint(VoiidColor.textOnAccent)
                    } else {
                        Text(step == .identity ? "Continue" : "Create community")
                            .font(VoiidFont.rounded(16.5, .semibold))
                    }
                }
                .foregroundColor(VoiidColor.textOnAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                    .fill(VoiidColor.accent))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!canContinue || creating)
            .opacity(canContinue ? 1 : 0.45)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
        .background(.bar)
    }

    // MARK: Create

    /// Icon first, then the community — and stop at the first failure, so a community is never
    /// created without the icon the host saw on screen.
    private func create() async {
        guard canContinue, !creating else { return }
        creating = true
        createError = nil
        defer { creating = false }
        do {
            var avatarKey: String?
            if let icon {
                do {
                    avatarKey = try await MediaService.shared.uploadCommunityImage(icon)
                } catch {
                    Haptics.error()
                    createError = "Couldn\u{2019}t upload the icon. Try again, or go back and remove it."
                    return
                }
            }
            let card = try await CommunityService.shared.create(
                handle: handle,
                name: trimmedName,
                description: nil,
                joinPolicy: joinPolicy,
                discoverable: true,
                category: category.isEmpty ? nil : category,
                avatarKey: avatarKey)
            Haptics.success()
            onCreate(card)
            dismiss()
        } catch {
            Haptics.error()
            // A 409 here is the race the advisory check cannot close: someone took the handle
            // between the check and the insert. Send the host back to the field that fixes it.
            if case APIError.http(409, _, _) = error {
                availability = .taken
                customHandle = handle
                createError = nil
                withAnimation(.easeOut(duration: 0.2)) { step = .identity }
                handleFocused = true
                return
            }
            createError = (error as? APIError)?.errorDescription ?? "Couldn\u{2019}t create that community."
        }
    }
}

// MARK: - Chip layout

/// Wraps chips onto as many lines as they need. A sideways-scrolling chip row hides half the
/// options behind a gesture nobody knows to make; eight short words fit on two lines.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview { CommunityCreateFlow() }

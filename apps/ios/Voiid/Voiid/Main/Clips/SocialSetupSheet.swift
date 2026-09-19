//
//  SocialSetupSheet.swift
//  Voiid
//
//  THE GATE — a creator profile is required before a first clip can be posted, and this is
//  where it gets created: on demand, at first post, not at signup (see 029's header for why
//  manufacturing a public identity for every account is both a privacy and a namespace
//  problem).
//
//  Replaces the single-field CreatorHandleSheet, which collected a handle and nothing else.
//  Three things it could not collect are not optional:
//
//    BIRTH DATE — India's DPDP Act treats everyone under 18 as a child and requires
//      verifiable parental consent plus a ban on behavioural advertising directed at them.
//      `creator_profiles.birth_date` has existed since 029 and nothing ever wrote to it, so
//      the column was there and the answer never was.
//
//    GUIDELINES — Apple Guideline 1.2 requires a EULA prohibiting objectionable content that
//      users actually agree to. The signup Terms screen covers the ACCOUNT; this is the
//      agreement to POST, taken at the step that creates the public posting identity.
//
//    INTERESTS — `creator_profiles.interests` seeds the recommendation feed. Also unwritten.
//
//  ── THIS IS PUBLIC, AND THE COPY SAYS SO ─────────────────────────────────────────
//  A creator handle is BROADCAST IDENTITY: visible to strangers, attached to every clip.
//  It is NOT the chat @username, which is half a private credential (username + PIN opens a
//  message request). They share one namespace so that a single @name can never mean two
//  different people, but they are different things and the sheet must not imply otherwise.
//
//  ── IT SURVIVES REINSTALL BECAUSE THE SERVER OWNS IT ────────────────────────────
//  Nothing here is cached on the device as the source of truth. `creator_profiles` is keyed
//  to `user_id`, and `auth.ts` resolves a phone number to the same `user_id` every time
//  (`on conflict (phone_number) do update`). So restoring an account on a new phone returns
//  the same handle, birth date and interests without this flow running again — the gate
//  reads `SocialEngine.me`, which is the server's answer, not a local flag.
//

import SwiftUI

struct SocialSetupSheet: View {
    @EnvironmentObject var creators: SocialEngine
    @Environment(\.dismiss) private var dismiss

    /// Called with the created profile once the gate is satisfied. The caller resumes
    /// whatever it was trying to do (posting a clip).
    var onCreated: (SocialService.Profile) -> Void

    // Step 1
    @State private var handle = ""
    @State private var displayName = ""
    @State private var bio = ""
    @State private var handleState: SocialEngine.HandleState = .idle
    @FocusState private var handleFocused: Bool

    // Step 2
    @State private var birthDate = Calendar.current.date(
        byAdding: .year, value: -20, to: Date()) ?? Date()

    // Step 3
    @State private var interests: Set<String> = []
    @State private var acceptedGuidelines = false
    @State private var showGuidelines = false

    @State private var step: Step = .identity
    @State private var submitting = false
    @State private var errorText: String?

    enum Step: Int, CaseIterable {
        case identity = 1
        case age = 2
        case interests = 3

        var title: String {
            switch self {
            case .identity:  "Social Identity"
            case .age:       "Age & Safety"
            case .interests: "Feed Tuning"
            }
        }

        /// Nil on the first step, which is what the back control reads to decide between
        /// stepping back and closing the sheet.
        var previous: Step? { Step(rawValue: rawValue - 1) }
    }

    // MARK: Derived

    private var normalized: String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var age: Int {
        max(0, Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0)
    }

    private var isUnder18: Bool { age < 18 }

    /// Submission needs only a well-formed handle. The availability check is ADVISORY —
    /// blocking on `.available` would strand the user whenever the check itself failed,
    /// and the create call re-validates under the real unique constraint regardless.
    private var stepValid: Bool {
        switch step {
        case .identity:
            return SocialEngine.isWellFormed(normalized) && handleState != .taken
        case .age:
            // 13 is the floor for having a profile at all. Under-18 is allowed through and
            // flagged, because DPDP's answer to a minor is restriction, not exclusion.
            return age >= 13
        case .interests:
            return interests.count >= 3 && acceptedGuidelines
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    progressIndicator
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.top, VoiidSpacing.xs)

                    ScrollView {
                        VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                            switch step {
                            case .identity:  identityStep
                            case .age:       ageStep
                            case .interests: interestsStep
                            }

                            if let errorText {
                                Text(errorText)
                                    .font(VoiidFont.footnote)
                                    .foregroundColor(VoiidColor.error)
                            }
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.top, VoiidSpacing.md)
                        .padding(.bottom, 120)
                    }
                    .scrollIndicators(.hidden)
                }

                footer
            }
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The system's own back affordance rather than a drawn chevron: it steps
                // backwards through the flow, and closes the sheet from the first step
                // because there is no earlier step to return to.
                ToolbarItem(placement: .cancellationAction) {
                    Button(step.previous == nil ? "Not now" : "Back") {
                        Haptics.tap()
                        if let previous = step.previous {
                            withAnimation { step = previous }
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: step)
        .sheet(isPresented: $showGuidelines) {
            ClipsGuidelinesSheet(
                accepted: acceptedGuidelines,
                onAgree: {
                    Haptics.success()
                    acceptedGuidelines = true
                    showGuidelines = false
                },
                onClose: { showGuidelines = false }
            )
        }
    }

    // MARK: Progress

    private var progressIndicator: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue
                              ? VoiidColor.primary : VoiidColor.fieldBorder)
                        .frame(height: 3.5)
                }
            }

            // The bars alone say how far, not where. Without this the button label ends up
            // carrying it ("Continue to Age & Safety") and crowds its own button.
            HStack {
                Text("Step \(step.rawValue) of \(Step.allCases.count)")
                    .font(VoiidFont.caption)
                    .foregroundColor(VoiidColor.textSecondary)
                Spacer()
                Text(step.title)
                    .font(VoiidFont.caption)
                    .foregroundColor(VoiidColor.primary)
            }
        }
    }

    // MARK: Step 1 — identity

    private var identityStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Create your Social Profile")
                    .font(VoiidFont.rounded(24, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text("One public identity for Clips, Games and Communities. This is how people find you.")
                    .font(VoiidFont.subhead)
                    .foregroundColor(VoiidColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
                Text("Handle")
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)

                HStack(spacing: 6) {
                    Text("@")
                        .font(VoiidFont.body)
                        .foregroundColor(VoiidColor.textSecondary)
                    TextField("yourname", text: $handle)
                        .focused($handleFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(VoiidFont.body)
                        .foregroundColor(VoiidColor.textPrimary)
                        .onChange(of: handle) { _, new in
                            creators.checkHandle(new) { handleState = $0 }
                        }

                    handleStatusGlyph
                }
                .padding(VoiidSpacing.md)
                .background(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .fill(VoiidColor.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(handleState == .taken ? VoiidColor.error : VoiidColor.fieldBorder,
                            lineWidth: 1))

                Text(handleHint)
                    .font(VoiidFont.caption)
                    .foregroundColor(handleState == .taken
                                     ? VoiidColor.error : VoiidColor.textSecondary)
            }

            field("Display name", text: $displayName, placeholder: "Your name")
            field("Bio", text: $bio, placeholder: "Optional")

            publicNotice
        }
    }

    @ViewBuilder
    private var handleStatusGlyph: some View {
        switch handleState {
        case .checking:
            ProgressView().controlSize(.small)
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundColor(VoiidColor.success)
        case .taken:
            Image(systemName: "xmark.circle.fill").foregroundColor(VoiidColor.error)
        default:
            EmptyView()
        }
    }

    private var handleHint: String {
        switch handleState {
        case .taken:     return "That handle is taken."
        case .available: return "Available."
        default:         return "3–20 characters, starting with a letter."
        }
    }

    private func field(_ label: String, text: Binding<String>,
                       placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
            Text(label)
                .font(VoiidFont.rounded(14, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
            TextField(placeholder, text: text)
                .font(VoiidFont.body)
                .foregroundColor(VoiidColor.textPrimary)
                .padding(VoiidSpacing.md)
                .background(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .fill(VoiidColor.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(VoiidColor.fieldBorder, lineWidth: 1))
        }
    }

    private var publicNotice: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
            Image(systemName: "globe")
                .font(.system(size: 15))
                .foregroundColor(VoiidColor.textSecondary)
            Text("Your handle, name and photo are public. They appear on your Clips, your community posts and your games. This is separate from your chat username, and your messages stay end-to-end encrypted.")
                .font(VoiidFont.caption)
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(VoiidSpacing.md)
        .background(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .fill(VoiidColor.surfaceCard))
    }

    // MARK: Step 2 — age

    private var ageStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("When is your birthday?")
                    .font(VoiidFont.rounded(24, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text("This sets your safety protections and is never shown on your profile.")
                    .font(VoiidFont.subhead)
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: VoiidSpacing.md) {
                DatePicker("Date of birth", selection: $birthDate,
                           in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()

                HStack(spacing: VoiidSpacing.sm) {
                    Image(systemName: age >= 13
                          ? "calendar.badge.checkmark" : "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(age >= 13 ? VoiidColor.primary : VoiidColor.error)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(age >= 13 ? "\(age) years old" : "You must be 13 or older")
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                        if age >= 13 {
                            Text(isUnder18 ? "Teen Safe protections on" : "Standard")
                                .font(VoiidFont.caption)
                                .foregroundColor(VoiidColor.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(VoiidSpacing.md)
            .background(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .fill(VoiidColor.surfaceCard))

            if isUnder18 && age >= 13 {
                teenNotice
            }

            HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14))
                    .foregroundColor(VoiidColor.textSecondary)
                Text("Your date of birth is never shown on your profile and never shared with anyone. It is used only to apply the right safety protections.")
                    .font(VoiidFont.caption)
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    /// Told, not hidden. DPDP bans behavioural advertising to minors and the UK's Children's
    /// Code wants profiling off by default AND legible — a feed that quietly behaves
    /// differently is the one a teenager works around.
    private var teenNotice: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(VoiidColor.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Teen Safe mode")
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text("Your feed won’t be personalised from your activity, and you won’t see targeted ads.")
                    .font(VoiidFont.caption)
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(VoiidSpacing.md)
        .background(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .fill(VoiidColor.warning.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.warning.opacity(0.3), lineWidth: 1))
    }

    // MARK: Step 3 — interests

    private var interestsStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What do you want to see?")
                    .font(VoiidFont.rounded(24, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text("Pick at least 3. You can change these any time.")
                    .font(VoiidFont.subhead)
                    .foregroundColor(VoiidColor.textSecondary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ClipTopic.all) { topic in
                    topicTile(topic)
                }
            }

            guidelinesConsent
        }
    }

    private func topicTile(_ topic: ClipTopic) -> some View {
        let on = interests.contains(topic.id)
        return Button {
            Haptics.selection()
            withAnimation(.easeOut(duration: 0.16)) {
                if on { interests.remove(topic.id) } else { interests.insert(topic.id) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: topic.icon)
                    .font(.system(size: 14))
                    .foregroundColor(on ? VoiidColor.primary : VoiidColor.textSecondary)
                Text(topic.name)
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if on {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(VoiidColor.primary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .fill(on ? VoiidColor.accentTint : VoiidColor.surfaceCard))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .stroke(on ? VoiidColor.primary : VoiidColor.fieldBorder,
                        lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// Reading and agreeing are two deliberate actions. Tapping "read" must not be what
    /// agrees on your behalf — that is the pattern that makes a consent tick meaningless.
    private var guidelinesConsent: some View {
        Button {
            Haptics.selection()
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) { acceptedGuidelines.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(acceptedGuidelines ? VoiidColor.primary : VoiidColor.fieldBorder,
                                  lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(acceptedGuidelines ? VoiidColor.primary : .clear))
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .opacity(acceptedGuidelines ? 1 : 0)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("I agree to the Community Guidelines")
                        .font(VoiidFont.rounded(14, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    Text("No harassment, hate, sexual content involving minors, or violent or illegal material. Accounts that post it are removed.")
                        .font(VoiidFont.caption)
                        .foregroundColor(VoiidColor.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        Haptics.tap()
                        showGuidelines = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("Read the full guidelines")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(VoiidFont.rounded(12, .semibold))
                        .foregroundColor(VoiidColor.primary)
                        .padding(.top, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(VoiidSpacing.md)
            .background(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .fill(VoiidColor.surfaceCard))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .stroke(acceptedGuidelines ? VoiidColor.primary : VoiidColor.fieldBorder,
                        lineWidth: acceptedGuidelines ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(acceptedGuidelines ? [.isSelected] : [])
        .accessibilityLabel("I agree to the Community Guidelines")
    }

    // MARK: Footer

    private var footer: some View {
        VStack {
            Spacer()
            VoiidPrimaryButton(
                title: submitting ? "Creating…"
                     : (step == .interests ? "Create profile" : "Continue"),
                action: advance
            )
            .disabled(!stepValid || submitting)
            .opacity(stepValid && !submitting ? 1 : 0.45)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.top, VoiidSpacing.sm)
            .padding(.bottom, VoiidSpacing.md)
            .background(.bar)
        }
    }

    // MARK: Actions

    private func advance() {
        Haptics.tap()
        errorText = nil
        switch step {
        case .identity: withAnimation { step = .age }
        case .age:      withAnimation { step = .interests }
        case .interests: Task { await submit() }
        }
    }

    private func submit() async {
        guard !submitting else { return }
        submitting = true
        defer { submitting = false }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        do {
            let profile = try await creators.createProfile(
                handle: normalized,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty,
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                linkURL: nil,
                birthDate: formatter.string(from: birthDate),
                interests: Array(interests).sorted()
            )
            Haptics.success()
            onCreated(profile)
            dismiss()
        } catch {
            errorText = (error as? APIError)?.errorDescription
                ?? "Couldn’t create your profile. Please try again."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Topics

struct ClipTopic: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String

    static let all: [ClipTopic] = [
        .init(id: "gaming",  name: "Gaming",        icon: "gamecontroller.fill"),
        .init(id: "tech",    name: "Tech & AI",     icon: "cpu.fill"),
        .init(id: "comedy",  name: "Comedy",        icon: "face.smiling.inverse"),
        .init(id: "cricket", name: "Cricket & Sport", icon: "figure.cricket"),
        .init(id: "music",   name: "Music",         icon: "music.note"),
        .init(id: "travel",  name: "Travel",        icon: "airplane"),
        .init(id: "fashion", name: "Fashion",       icon: "tshirt.fill"),
        .init(id: "food",    name: "Food",          icon: "fork.knife"),
        .init(id: "design",  name: "Design & Art",  icon: "paintbrush.fill"),
        .init(id: "anime",   name: "Anime & Film",  icon: "film.fill"),
        .init(id: "finance", name: "Finance",       icon: "chart.line.uptrend.xyaxis"),
        .init(id: "motors",  name: "Cars & Speed",  icon: "car.fill"),
    ]
}

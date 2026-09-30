//
//  CallLogView.swift
//  Voiid
//
//  The Calls tab — every call, newest first.
//
//  WHY THIS EXISTS. Call history was written to `call_history` from the first call the app
//  ever placed, but the only way to SEE it was to open the specific chat it happened in, or
//  that person's profile. So "who called me while I was out?" — the single question a call
//  log answers — had no answer anywhere in the app. The data was there the whole time; the
//  screen was not.
//
//  The local log preserves device-specific outcomes. Server reconciliation also recovers
//  unanswered direct calls whose incoming push never reached this device. Answered calls
//  from another phone and a complete cross-device history are not restored.
//
//  NATIVE, ON PURPOSE. A plain List under a system large title, with `.searchable`, a
//  segmented filter, swipe actions and long-press menus — the grammar of the iOS Phone app.
//  Design reference: Voiid Ui/Chat/CallsScreen.swift.
//
//  NO KEYPAD. Voiid calls Voiid ACCOUNTS, not phone numbers; a dial pad would invite typing a
//  number Voiid cannot ring. "New Call" picks a person instead.
//

import SwiftUI
// `.receive(on:)` below is a Combine operator on NotificationCenter's publisher. SwiftUI
// re-exports enough of Combine for `onReceive` itself, but not for the operator, so this
// import is what makes the main-thread hop compile.
import Combine

struct CallLogView: View {
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var session: AppSession
    @Environment(\.scenePhase) private var scenePhase

    @State private var entries: [LocalStore.CallLogEntry] = []
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var confirmClear = false
    @State private var newCall = false
    @State private var detail: LocalStore.CallLogEntry?
    @State private var openConversation: VConversation?
    @State private var activeCall: CallRequest?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", missed = "Missed"
        var id: String { rawValue }
    }

    private var visible: [LocalStore.CallLogEntry] {
        entries.filter { entry in
            (filter == .all || entry.missed)
                && (query.isEmpty || name(for: entry).localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.0) { day, calls in
                    Section(day) {
                        ForEach(calls) { row($0) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Top under the nav bar, bottom under the floating tab bar — no hard bars on 26.
            .softScrollEdge([.top, .bottom])
            .background(VoiidColor.background.ignoresSafeArea())
            .overlay { emptyState }
            // The tab bar is painted OVER this page, not into its safe area.
            .contentMargins(.bottom, session.bottomInset, for: .scrollContent)
            .navigationTitle("Calls")
            // The title in Voiid's screen-title face (26pt rounded bold), the same as Chats,
            // Moments and Communities. Everything else on this page is the reference's.
            .background(LargeTitleFont(size: 26))
            .searchable(text: $query, prompt: "Search calls")
            .toolbar { toolbar }
            .navigationDestination(item: $detail) { entry in
                CallDetailView(entry: entry,
                               name: name(for: entry),
                               history: history(like: entry),
                               onCall: { kind in call(entry, kind) },
                               onMessage: conversation(for: entry).map { conv in { openConversation = conv } })
            }
            .navigationDestination(item: $openConversation) { ChatDetailView(conversation: $0).id($0.id) }
            .confirmationDialog("Clear all calls?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Clear All Calls", role: .destructive) {
                    LocalStore.clearCallHistory()
                    entries = LocalStore.allCalls()
                    Haptics.success()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                // Say what is actually lost. This is device-local, so "on this phone" is
                // not a hedge — it is the whole truth.
                Text("Your call history is removed from this phone. It doesn't affect the other person's log.")
            }
        }
        .tint(VoiidColor.accentInk)
        .sheet(isPresented: $newCall) {
            NewCallSheet(conversations: chat.directConversations + chat.groupConversations) { conv, kind in
                place(conv, kind)
            }
        }
        // ChatStore injected by hand — a fullScreenCover does not reliably inherit it, and
        // CallScreen crashes at runtime without it. See ChatsHomeView.
        .fullScreenCover(item: $activeCall) { CallScreen(request: $0).environmentObject(chat) }
        // Root tab: bring the bar back whenever nothing is pushed. Detail screens hide it.
        .onAppear { if detail == nil && openConversation == nil { session.hideTabBar = false } }
        .onChange(of: detail == nil && openConversation == nil) { _, atRoot in
            if atRoot { session.hideTabBar = false }
        }
        .task {
            entries = LocalStore.allCalls()
            await LocalStore.recoverMissedCalls()
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalStore.callHistoryDidChange)
            .receive(on: RunLoop.main)) { _ in
            entries = LocalStore.allCalls()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                entries = LocalStore.allCalls()
                Task { await LocalStore.recoverMissedCalls() }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // All / Missed. Two options, so a segmented control rather than a menu — the choice
        // is visible and one tap away, which is what a filter this small should be.
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: filter) { Haptics.selection() }
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu("More", systemImage: "ellipsis") {
                Button("Clear All Calls", systemImage: "trash", role: .destructive) {
                    Haptics.rigid(); confirmClear = true
                }
                .disabled(entries.isEmpty)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("New Call", systemImage: "phone.badge.plus") {
                Haptics.tap(); newCall = true
            }
        }
    }

    // MARK: - Row

    private func row(_ entry: LocalStore.CallLogEntry) -> some View {
        let name = name(for: entry)
        // Tapping the row calls back the same way, as in Phone; ⓘ opens the details. Both are
        // borderless, which is what lets a List row hold two independent tap targets.
        return HStack(spacing: 12) {
            Button {
                Haptics.tap()
                call(entry, entry.isVideo ? .video : .voice)
            } label: {
                HStack(spacing: 12) {
                    ProfileAvatarButton(photoURL: photoURL(for: entry), name: name, size: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        // MISSED IS RED IN THE NAME, and the words and glyph carry it too —
                        // colour alone fails for ~1 in 12 men.
                        Text(name)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(entry.missed ? VoiidColor.error : VoiidColor.textPrimary)
                            .lineLimit(1)

                        Label(CallLogText.summary(entry), systemImage: CallLogText.icon(entry))
                            .labelStyle(CompactLabelStyle())
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(VoiidColor.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text(entry.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(name), \(CallLogText.summary(entry))")
            .accessibilityHint("Calls back")

            Button {
                Haptics.tap(); detail = entry
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(VoiidColor.accentInk)
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Details for \(name)")
        }
        // A sideways drag on a row reveals its actions; it must not also switch tabs. The
        // header and empty space still carry the tab swipe.
        .voiidBlocksTabSwipe()
        .listRowBackground(VoiidColor.background)
        .listRowSeparatorTint(VoiidColor.divider)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                LocalStore.deleteCall(id: entry.id)
            }
        }
        .swipeActions(edge: .leading) {
            if let conv = conversation(for: entry) {
                Button("Message", systemImage: "message.fill") { openConversation = conv }
                    .tint(VoiidColor.accent)
            }
        }
        .contextMenu {
            Button("Voice Call", systemImage: "phone") { call(entry, .voice) }
            Button("Video Call", systemImage: "video") { call(entry, .video) }
            if let conv = conversation(for: entry) {
                Button("Message", systemImage: "message") { openConversation = conv }
            }
            Divider()
            Button("Delete from Recents", systemImage: "trash", role: .destructive) {
                LocalStore.deleteCall(id: entry.id)
            }
        }
    }

    // MARK: - Empty

    @ViewBuilder
    private var emptyState: some View {
        if visible.isEmpty {
            if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if filter == .missed && !entries.isEmpty {
                // A filter that matches nothing is NOT the same as having no history —
                // "No calls yet" here would read as a broken log.
                ContentUnavailableView("No Missed Calls", systemImage: "phone.down")
            } else {
                ContentUnavailableView {
                    Label("No Calls Yet", systemImage: "phone")
                } description: {
                    Text("Voice and video calls on Voiid are end-to-end encrypted.")
                } actions: {
                    Button("Start a Call") { newCall = true }
                        .prominentAction()
                }
            }
        }
    }

    // MARK: - Grouping

    /// Today / Yesterday / weekday / date — how the Phone app groups, so a glance answers "when".
    private var grouped: [(String, [LocalStore.CallLogEntry])] {
        let cal = Calendar.current
        var order: [String] = []
        var buckets: [String: [LocalStore.CallLogEntry]] = [:]
        for e in visible {
            let day = cal.startOfDay(for: e.startedAt)
            let key: String
            if cal.isDateInToday(day) { key = "Today" }
            else if cal.isDateInYesterday(day) { key = "Yesterday" }
            else if Date().timeIntervalSince(day) < 6 * 86_400 { key = day.formatted(.dateTime.weekday(.wide)) }
            else { key = day.formatted(.dateTime.day().month(.wide)) }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(e)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    // MARK: - Lookups

    private func name(for entry: LocalStore.CallLogEntry) -> String {
        if let peer = entry.peerUserId {
            let resolved = UserDirectory.shared.displayName(peer)
            if !resolved.isEmpty { return resolved }
        }
        // A group call has no single peer, and an unknown 1:1 still has a chat with a name.
        return conversation(for: entry)?.title ?? "Unknown"
    }

    private func photoURL(for entry: LocalStore.CallLogEntry) -> String? {
        entry.peerUserId.flatMap { UserDirectory.shared.photoURL($0) } ?? conversation(for: entry)?.photoURL
    }

    private func conversation(for entry: LocalStore.CallLogEntry) -> VConversation? {
        guard let cid = entry.conversationId else { return nil }
        return (chat.directConversations + chat.groupConversations).first { $0.id == cid }
    }

    /// Every call in the same conversation (or with the same person, for older rows).
    private func history(like entry: LocalStore.CallLogEntry) -> [LocalStore.CallLogEntry] {
        entries.filter {
            if let cid = entry.conversationId { return $0.conversationId == cid }
            return entry.peerUserId != nil && $0.peerUserId == entry.peerUserId
        }
    }

    // MARK: - Calling

    private func call(_ entry: LocalStore.CallLogEntry, _ kind: CallKind) {
        guard let conv = conversation(for: entry) else {
            // No chat on this phone to resolve the peer or the group from — open nothing
            // rather than place a call CallScreen would silently simulate.
            Haptics.error(); return
        }
        place(conv, kind)
    }

    private func place(_ conv: VConversation, _ kind: CallKind) {
        Task { activeCall = await CallLauncher.request(for: conv, kind: kind) }
    }
}

// MARK: - Copy

/// Row and detail copy. State is carried by the words AND the icon, never by red alone.
enum CallLogText {
    static func summary(_ e: LocalStore.CallLogEntry) -> String {
        let medium = e.isVideo ? "video" : "voice"
        // Still ringing: not missed yet (see LocalStore.isRinging).
        if e.ringing { return (e.incoming ? "Incoming \(medium)" : "Outgoing \(medium)") + " · now" }
        switch e.outcome {
        case "answered":
            let d = e.duration.map { " · " + duration($0) } ?? ""
            return (e.incoming ? "Incoming \(medium)" : "Outgoing \(medium)") + d
        case "busy":     return "Outgoing \(medium) · Busy"
        case "declined": return e.incoming ? "Declined \(medium) call" : "\(medium.capitalized) call declined"
        case "failed":   return "Failed \(medium) call"
        default:         return e.incoming ? "Missed \(medium) call" : "Outgoing \(medium) · No answer"
        }
    }

    static func icon(_ e: LocalStore.CallLogEntry) -> String {
        if e.isVideo { return "video.fill" }
        if e.missed || e.outcome == "declined" { return "phone.down.fill" }
        return e.incoming ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill"
    }

    static func duration(_ d: TimeInterval) -> String {
        let s = Int(d)
        if s < 60 { return "\(s) sec" }
        let m = s / 60
        return m < 60 ? "\(m) min" : "\(m / 60) hr \(m % 60) min"
    }
}

/// Icon and text tight together, icon small — the Phone app's "↙ Incoming" subline.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - Detail

private struct CallDetailView: View {
    let entry: LocalStore.CallLogEntry
    let name: String
    let history: [LocalStore.CallLogEntry]
    var onCall: (CallKind) -> Void
    /// nil when there is no chat on this phone to open.
    var onMessage: (() -> Void)?

    @EnvironmentObject var session: AppSession

    private var phone: String? {
        entry.peerUserId.flatMap { UserDirectory.shared.user($0)?.phoneE164 }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: VoiidSpacing.md) {
                    ProfileAvatarButton(photoURL: entry.peerUserId.flatMap { UserDirectory.shared.photoURL($0) },
                                        name: name, size: 88)
                    VStack(spacing: 4) {
                        Text(name)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(VoiidColor.textPrimary)
                        if let phone {
                            Text(phone)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(VoiidColor.textSecondary)
                        }
                    }
                    HStack(spacing: 10) {
                        if let onMessage { action("Message", "message.fill", onMessage) }
                        action("Voice", "phone.fill") { onCall(.voice) }
                        action("Video", "video.fill") { onCall(.video) }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(history) { call in
                    HStack {
                        Label {
                            Text(CallLogText.summary(call))
                                .foregroundStyle(call.missed ? VoiidColor.error : VoiidColor.textPrimary)
                        } icon: {
                            Image(systemName: CallLogText.icon(call))
                                .foregroundStyle(call.missed ? VoiidColor.error : VoiidColor.textSecondary)
                        }
                        Spacer()
                        Text(call.startedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                            .foregroundStyle(VoiidColor.textSecondary)
                    }
                    .font(.system(.subheadline, design: .rounded))
                }
            } header: {
                Text("Calls")
            } footer: {
                Label("Calls with \(name) are end-to-end encrypted.", systemImage: "lock.fill")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .softScrollEdge()
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.hideTabBar = true }
    }

    /// Contacts-card action tile: icon over label, equal widths.
    private func action(_ title: String, _ icon: String, _ perform: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap(); perform()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.system(.caption, design: .rounded, weight: .medium))
            }
            .foregroundStyle(VoiidColor.accentInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - New call

/// People and groups you can ring. A picker, not a keypad — see the file note.
private struct NewCallSheet: View {
    let conversations: [VConversation]
    var onCall: (VConversation, CallKind) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [VConversation] {
        conversations.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                let people = matches.filter { $0.type != .group }
                let groups = matches.filter { $0.type == .group }
                if !people.isEmpty { Section("Contacts") { ForEach(people, content: row) } }
                if !groups.isEmpty { Section("Groups") { ForEach(groups, content: row) } }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .softScrollEdge()
            .background(VoiidColor.background.ignoresSafeArea())
            .overlay {
                if matches.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No Chats Yet", systemImage: "person.2",
                                               description: Text("Start a chat with someone to call them."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name")
            .navigationTitle("New Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .tint(VoiidColor.accentInk)
    }

    private func row(_ conv: VConversation) -> some View {
        HStack(spacing: 12) {
            ProfileAvatarButton(photoURL: conv.photoURL, name: conv.title, size: 40)
            Text(conv.title)
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(VoiidColor.textPrimary)
                .lineLimit(1)
            Spacer()
            callButton(conv, .voice, "phone.fill", "Voice call")
            callButton(conv, .video, "video.fill", "Video call")
        }
    }

    private func callButton(_ conv: VConversation, _ kind: CallKind, _ icon: String, _ label: String) -> some View {
        Button {
            Haptics.tap()
            dismiss()
            // Let the sheet go before the call covers the screen, or the two animations fight.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onCall(conv, kind) }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VoiidColor.accentInk)
                .frame(width: 38, height: 38)
                .background(VoiidColor.accentTint, in: Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(label) \(conv.title)")
    }
}

/// Sets the large navigation title's font on the navigation bar hosting this view. SwiftUI has
/// no per-screen API for it; this reaches the bar once the view is in the hierarchy.
private struct LargeTitleFont: UIViewControllerRepresentable {
    let size: CGFloat

    func makeUIViewController(context: Context) -> Controller { Controller(size: size) }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        let size: CGFloat
        init(size: CGFloat) { self.size = size; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        private func apply() {
            guard let bar = navigationController?.navigationBar ?? parent?.navigationController?.navigationBar
            else { return }
            let base = UIFont.systemFont(ofSize: size, weight: .bold)
            let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
            // Copies, reassigned: only the font changes, the bar's backgrounds stay as they are.
            // A nil scroll-edge appearance is left nil — iOS derives it from the standard one.
            let standard = bar.standardAppearance.copy()
            standard.largeTitleTextAttributes[.font] = font
            bar.standardAppearance = standard
            if let edge = bar.scrollEdgeAppearance?.copy() {
                edge.largeTitleTextAttributes[.font] = font
                bar.scrollEdgeAppearance = edge
            }
        }
    }
}

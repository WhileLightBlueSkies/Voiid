//
//  Stores.swift
//  Voiid
//
//  Local, in-memory app state (NO network, NO crypto — dummy experience build).
//  Everything is interactive: sending a message appends it, marks it sent→delivered→read
//  on timers, and simulates a reply, so the app *feels* real end-to-end on a device.
//

import SwiftUI
import Combine

// MARK: - Session / onboarding

@MainActor
final class AppSession: ObservableObject {
    enum Route { case onboarding, recovery, main }
    @Published var route: Route
    // Empty until the REAL profile loads (loadLocalProfile → refreshServerProfile). Never a
    // dummy "You / +91 …" placeholder that could flash on screen before the real data arrives.
    @Published var profile = VUser(id: "me", fullName: "", phoneNumber: "")
    /// Hides the bottom tab bar when a full-screen child (e.g. a chat) is open.
    ///
    /// OPT-OUT, and that is the flaw: every pushed screen has to remember to set this true,
    /// and every root tab has to remember to set it back to false. Miss either and the bar
    /// leaks into a chat or vanishes from a tab. `RootTabView` therefore ALSO forces it false
    /// whenever the selected tab changes, so a forgotten reset self-heals on the next tab tap
    /// rather than stranding the user with no navigation.
    /// ── A COUNT, NOT A BOOL ─────────────────────────────────────────────────────────
    /// A Bool broke the moment two screens both wanted it. Pushing Contact from Conversation
    /// runs Contact's appear FIRST and Conversation's disappear SECOND — so the outgoing screen
    /// set it back to false and the tab bar reappeared over the screen that had just asked to
    /// hide it. Lifecycle ORDER is not guaranteed, so no amount of moving the call between
    /// `onAppear` and `task` fixes it reliably; the tab-change self-heal described above is a
    /// symptom of that, not a cure.
    ///
    /// Counting does fix it: each screen adds one on the way in and removes one on the way out,
    /// and the bar stays hidden while anyone is still asking. Order stops mattering.
    ///
    /// `hideTabBar` keeps its Bool shape so all 52 existing call sites still compile and still
    /// mean what they meant — assigning false is a RESET, which is what a root screen wants.
    @Published private var hideRequests = 0

    var hideTabBar: Bool {
        get { hideRequests > 0 }
        set { hideRequests = newValue ? max(hideRequests, 1) : 0 }
    }

    /// Called by a screen that wants the bar hidden for its lifetime.
    func requestHideTabBar() { hideRequests += 1 }

    /// Called when that screen goes away.
    func releaseHideTabBar() { hideRequests = max(0, hideRequests - 1) }

    /// Clears every request. Used on a tab change, which always lands on a root screen — a
    /// count left high by a screen that failed to release would strand the user with no
    /// navigation at all.
    func resetChrome() { hideRequests = 0 }

    /// What a page has to scroll clear of at the bottom: the tab bar.
    ///
    /// ── ONE PROPERTY, NOT PER-SCREEN ARITHMETIC ─────────────────────────────────────
    /// The bar is painted OVER the page (a ZStack sibling), not inserted into its safe area,
    /// so every scrolling tab screen has to hold its own content clear of it. Five screens each
    /// computing `session.tabBarHeight + something` is five chances to get it wrong, and five
    /// of the seven had already got it wrong by doing nothing at all — their last row sits
    /// under the bar.
    ///
    /// The floor covers the frame before the bar has measured itself, when `tabBarHeight` is
    /// still 0; hiding the bar collapses it to 0, so a full-screen child inherits no phantom gap.
    var bottomInset: CGFloat {
        hideTabBar ? 0 : max(tabBarHeight, 84)
    }
    /// The MEASURED height of the custom bottom tab bar, including its home-indicator
    /// padding — published by RootTabView, which is the only view that knows it.
    ///
    /// The bar is NOT a TabView bar: RootTabView draws it as a ZStack sibling painted
    /// OVER the active page, so it contributes nothing to any page's safe area. A page
    /// that anchors its own chrome to the bottom therefore lands UNDERNEATH the bar
    /// unless it insets by this value. `0` whenever the bar is hidden, so a full-screen
    /// child inherits no phantom gap.
    @Published var tabBarHeight: CGFloat = 0

    private let auth = AuthService.shared

    /// Where the local copy of your own profile lives. Small and flat, so UserDefaults
    /// is the right tool — it is read during launch, before the database is touched,
    /// and it must never be the reason a launch blocks.
    private static let profileKey = "voiid.me.profile.v1"
    /// The VERIFIED E.164 phone from the OTP flow. The server never stores the phone, so
    /// this UserDefaults key is the only source of the user's REAL number.
    static let verifiedPhoneKey = "voiid.me.phone.e164"

    /// Called from the OTP screen on a successful verification. The one place the real
    /// number is known.
    static func saveVerifiedPhone(_ e164: String) {
        UserDefaults.standard.set(e164, forKey: verifiedPhoneKey)
    }

    init() {
        // Resume straight to the app if we already hold a valid session token.
        let account = TokenStore.shared.userId ?? ""
        let readyKey = "voiid.recovery.ready.\(account)"
        // Recover completed restores from builds that only set readiness on UI dismissal.
        let restored = BackupManager.shared.lastCompletedRestore != nil && BackupManager.shared.hasLocalSecret
        if restored { UserDefaults.standard.set(true, forKey: readyKey) }
        route = AuthService.shared.isAuthenticated
            ? (UserDefaults.standard.bool(forKey: readyKey) ? .main : .recovery)
            : .onboarding
        loadLocalProfile()
        // Show the REAL verified number, never DummyData's placeholder. Prefer the value
        // captured at OTP time; fall back to Firebase's persisted signed-in user (covers
        // accounts that logged in BEFORE we saved it) and persist that for next launch.
        // Empty (→ "—" in Settings) only if truly unknown, but NEVER a fake number.
        if let saved = UserDefaults.standard.string(forKey: Self.verifiedPhoneKey), !saved.isEmpty {
            profile.phoneNumber = saved
        } else if let fromFirebase = FirebasePhoneAuth.currentPhoneNumber {
            profile.phoneNumber = fromFirebase
            Self.saveVerifiedPhone(fromFirebase)
        } else {
            profile.phoneNumber = ""
        }
        // On relaunch of an already-authenticated session, pull the authoritative profile
        // from the server so a reinstall / new device shows the REAL name, photo, bio and
        // username — not a stale local copy or a placeholder.
        if AuthService.shared.isAuthenticated {
            Task { await refreshServerProfile() }
        }
    }

    /// Fetch this account's real profile from the server and merge it into `profile`.
    ///
    /// Call after login and on launch. `GET /users/:id` is the source of truth for
    /// full_name / photo_url / bio / username; the phone number is NOT server-held (it
    /// comes from the OTP flow), so it is preserved from local state. Every field is
    /// applied only when the server actually returned it, so this never blanks a value.
    func refreshServerProfile() async {
        guard let id = auth.userId else { return }
        guard let p = try? await ChatService.shared.userProfile(userId: id) else { return }
        if let n = p.name, !n.isEmpty { profile.fullName = n }
        if let url = p.photoURL, !url.isEmpty { profile.photoURL = url }
        if let bio = p.about, !bio.isEmpty { profile.bio = bio }
        if let u = p.username, !u.isEmpty { profile.username = u }
        // ASSIGNED UNCONDITIONALLY, unlike every field above it.
        //
        // The others use "only if the server sent something" because a blank from the server
        // is more likely to be a gap than an intention, and blanking a name on a bad response
        // is worse than keeping a stale one. Status is the opposite: clearing it is a normal,
        // deliberate act, and skipping the nil would make "no status" the one setting this
        // device could never learn about — it would keep showing a status the user removed on
        // their other phone, forever.
        profile.statusText = p.statusText
        // The server returns the phone number ONLY for our own profile — the authoritative,
        // Firebase-independent source. Use it if we don't already have one (e.g. an account
        // that logged in before we captured it at OTP), and persist it for offline launches.
        if profile.phoneNumber.isEmpty, let phone = p.phoneNumber, !phone.isEmpty {
            profile.phoneNumber = phone
            Self.saveVerifiedPhone(phone)
        }
        persistLocalProfile()
    }

    // MARK: - Own profile
    //
    // This was hardcoded to `DummyData.me` — every screen that showed "your" name or
    // photo was showing a placeholder, and there was nowhere to put a real one. It is
    // now persisted locally and synced, like everything else.

    private struct StoredProfile: Codable {
        var fullName: String
        var phoneNumber: String
        var photoURL: String?
        var email: String?
        var bio: String?
        var username: String?
        /// Optional so an EXISTING stored blob — written before this field existed — still
        /// decodes. A non-optional addition here would fail the whole decode and silently
        /// reset every user's locally-cached name and photo on first launch after update.
        var statusText: String?
    }

    private func loadLocalProfile() {
        guard let data = UserDefaults.standard.data(forKey: Self.profileKey),
              let stored = try? JSONDecoder().decode(StoredProfile.self, from: data)
        else { return }
        profile = VUser(id: auth.userId ?? "me",
                        fullName: stored.fullName,
                        phoneNumber: stored.phoneNumber,
                        email: stored.email,
                        photoName: nil,
                        photoURL: stored.photoURL,
                        username: stored.username,
                        bio: stored.bio,
                        statusText: stored.statusText)
    }

    private func persistLocalProfile() {
        let stored = StoredProfile(fullName: profile.fullName,
                                   phoneNumber: profile.phoneNumber,
                                   photoURL: profile.photoURL,
                                   email: profile.email,
                                   bio: profile.bio,
                                   username: profile.username,
                                   statusText: profile.statusText)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        }
    }

    /// Update your profile locally and immediately. Callers sync to the server
    /// separately; a failed sync must not undo what the user sees.
    func updateProfile(fullName: String? = nil, photoURL: String? = nil,
                       phoneNumber: String? = nil, email: String? = nil,
                       bio: String? = nil, username: String? = nil) {
        if let fullName { profile.fullName = fullName }
        if let photoURL { profile.photoURL = photoURL }
        if let phoneNumber { profile.phoneNumber = phoneNumber }
        if let email { profile.email = email }
        if let bio { profile.bio = bio }
        if let username { profile.username = username }
        persistLocalProfile()
    }

    /// Set or clear the availability status, server first.
    ///
    /// SERVER FIRST, unlike `updateProfile` above, and the difference is deliberate. That one
    /// is optimistic because the value it writes is one the user typed and can see; the point
    /// of a status is what OTHER people see, so "it looks set on my phone" is not the outcome
    /// being bought. Showing it as changed before the server has it would report success for
    /// a status nobody else can read. The caller renders its own in-flight state and gets a
    /// thrown error to surface if the write fails.
    ///
    /// Local state is written only after the round trip succeeds, so a failure leaves the UI
    /// showing what is actually stored rather than a value that exists on one device.
    func setStatus(_ status: AvailabilityStatus?) async throws {
        _ = try await ProfileService.shared.updateStatus(status)
        profile.statusText = status?.rawValue
        persistLocalProfile()
    }

    /// The authenticated user's id (our backend id), once logged in.
    var userId: String? { auth.userId }

    /// Called at the end of onboarding once a real session token exists
    /// (onboarding logs in via AuthService before calling this).
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "voiid.recovery.ready.\(TokenStore.shared.userId ?? "")")
        withAnimation(.easeInOut) { route = .main }
    }

    /// Clears the auth token and this account's own profile.
    ///
    /// It does NOT wipe the local database, the plaintext message blob, the E2E keychain
    /// or the registered VoIP token — that is `SessionTeardown.wipeLocalAccountState()`,
    /// which the Log Out row runs immediately BEFORE calling this (before, because the
    /// teardown's VoIP unregister still needs the JWT). Call them in that order or the
    /// previous account's data survives on the device.
    func signOut() {
        PrivacySettings.shared.resetVisibility()
        auth.logout()
        // Your profile is per-account state; leaving it behind would show the previous
        // user's name and photo on the next login.
        UserDefaults.standard.removeObject(forKey: Self.profileKey)
        UserDefaults.standard.removeObject(forKey: Self.verifiedPhoneKey)
        profile = VUser(id: "me", fullName: "", phoneNumber: "")
        // In-memory stores outlive the session (they are @StateObjects on ContentView),
        // so they have to be told.
        NotificationCenter.default.post(name: .voiidDidSignOut, object: nil)
        withAnimation(.easeInOut) { route = .onboarding }
    }
}

/// Posted by `AppSession.signOut()`. Anything holding per-account state in memory
/// observes this and drops it.
extension Notification.Name {
    static let voiidDidSignOut = Notification.Name("voiidDidSignOut")
}

// MARK: - Chat store (the heart of the "feels real" experience)

@MainActor
final class ChatStore: ObservableObject {
    // REAL backend data — starts empty, loaded via `loadConversations()`. A new
    // account shows an empty list, which confirms we're reading the live server
    // (not mock). Message content is still E2EE/not-yet-decrypted (placeholder).
    @Published var directConversations: [VConversation] = []
    /// False until the first server load finishes.
    ///
    /// WITHOUT THIS "still loading" and "you have no chats" render identically — a blank
    /// screen. On a fresh install that blank is the first thing a new user ever sees, and it
    /// is indistinguishable from the app being broken. Local chats paint instantly from
    /// SQLite, so this only ever gates the genuinely-empty case.
    @Published var didLoadConversations = false
    @Published var groupConversations: [VConversation] = []
    @Published var messagesByConversation: [String: [VMessage]] = [:] {
        didSet { mergeCache.removeAll(keepingCapacity: true) }
    }
    /// Finished calls per conversation, as transcript bubbles. Kept SEPARATE from the message
    /// map and merged on read: a call log is not a message, is never sent over the wire, and
    /// must not be persisted into the message store, previewed, or counted as unread.
    @Published var callLogsByConversation: [String: [VMessage]] = [:] {
        didSet { mergeCache.removeAll(keepingCapacity: true) }
    }
    @Published var typingConversations: Set<String> = []
    /// Pending auto-clears, one per participant. See the onTyping handler: a "stop" that
    /// never arrives would otherwise strand the indicator forever.
    private var typingExpiry: [String: DispatchWorkItem] = [:]
    private var typingUsers: [String: Set<String>] = [:]
    @Published var loadError: String?
    @Published var reactionError: String?
    @Published var mediaSendError: String?
    @Published var deletionError: String?
    private var deletingMessages: Set<ReactionKey> = []
    // Uploads have no engine row until the server accepts them. Keep their UI rows
    // separately so incoming messages/receipts cannot erase an in-flight or failed send.
    private var pendingMediaMessages: [String: VMessage] = [:]
    /// What a media send needs to be tried again from its red bubble. Held in memory only,
    /// for the bubbles that gave up — the bytes are already on the person's phone.
    private struct MediaPayload { let data: Data; let mime: String; let caption: String; let filename: String? }
    private var failedMediaPayloads: [String: MediaPayload] = [:]
    private struct ReactionKey: Hashable {
        let conversationId: String
        let messageId: String
    }
    private struct PendingReaction {
        let id = UUID()
        let userId: String
        let emoji: String?
    }
    private var pendingReactions: [ReactionKey: PendingReaction] = [:]
    private var reactionTasks: [ReactionKey: Task<Void, Never>] = [:]

    init() {
        // Sign-out has to empty this store. It is a @StateObject on ContentView, so it
        // survives the route change back to onboarding, and `loadConversations()` is
        // local-first — a stale array would render the PREVIOUS user's chat grid to the
        // next account before the network could correct it.
        NotificationCenter.default.addObserver(forName: .voiidDidSignOut,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.reset() }
        }
        // The connection came back: send every text that was waiting for it, now, rather
        // than whenever each chat is next opened. Media loops wake on their own.
        networkObserver = ChatNetwork.shared.$generation.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.flushAllPending() }
        }
    }

    private var networkObserver: AnyCancellable?

    private func flushAllPending() {
        for conversationId in ChatEngine.shared.conversationsWithPendingText() {
            guard let conv = directConversations.first(where: { $0.id == conversationId }) else { continue }
            Task {
                guard let peer = try? await peerUserId(for: conv) else { return }
                await ChatEngine.shared.flushPending(conversationId: conversationId, peerUserId: peer)
                refresh(conversationId)
            }
        }
    }

    /// Drop every trace of the signed-out account held in memory.
    func reset() {
        directConversations = []
        groupConversations = []
        communityConversations = []
        messagesByConversation = [:]
        typingExpiry.values.forEach { $0.cancel() }
        typingExpiry = [:]
        typingUsers = [:]
        typingConversations = []
        loadError = nil
        reactionError = nil
        mediaSendError = nil
        deletionError = nil
        deletingMessages = []
        pendingMediaMessages = [:]
        reactionTasks.values.forEach { $0.cancel() }
        reactionTasks = [:]
        pendingReactions = [:]
    }

    /// Load conversations LOCAL-FIRST, then reconcile with the server.
    ///
    /// Order matters. Previously this was network-only, so a failed GET left the
    /// arrays empty and the user saw a blank chat grid even though their entire
    /// message history was on disk — the messages were unreachable because nothing
    /// knew which conversations existed. Now the database answers first and the
    /// network merely updates it: offline, you see your chats.
    // Account-scoped, authoritative list membership. Keep channel transcripts in
    // LocalStore for Communities, but never infer a standalone group from MLS type.
    private var standaloneGroupIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: standaloneGroupKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: standaloneGroupKey) }
    }
    private var communityChannelIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: standaloneGroupKey + ".channels") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: standaloneGroupKey + ".channels") }
    }
    /// Community host threads: a member's conversation with a community's hosts. Kept out of
    /// the Groups list — the member reaches it from the community page, the hosts from the
    /// community inbox. Persisted so the cached list is right before the network answers.
    private var hostThreadIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: standaloneGroupKey + ".hostThreads") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: standaloneGroupKey + ".hostThreads") }
    }
    private var communityConversations: [VConversation] = []

    /// Any conversation this account is in, whatever list it lives in — chats, groups, or
    /// community-owned (channels and host threads, which are groups underneath and appear in
    /// no list). Opening a community thread has to find it here: searching the chats list
    /// alone never did, so the inbox and the Message button said it "isn't available".
    func conversation(id: String) -> VConversation? {
        (directConversations + groupConversations + communityConversations).first { $0.id == id }
    }
    private var encryptedGroupConversations: [VConversation] { groupConversations + communityConversations }
    private var standaloneGroupKey: String {
        "voiid.standalone-groups.v1.\(TokenStore.shared.userId ?? "signed-out")"
    }
    private var loadingConversationList = false
    private var conversationListWaiters: [CheckedContinuation<Void, Never>] = []

    func loadConversations() async {
        if loadingConversationList {
            // Incoming messages must wait for the list they are about to look up.
            await withCheckedContinuation { conversationListWaiters.append($0) }
            return
        }
        loadingConversationList = true
        defer {
            loadingConversationList = false
            let waiters = conversationListWaiters
            conversationListWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let accountID = TokenStore.shared.userId
        let previousGroupIDs = standaloneGroupIDs
        startRealtime()

        // One-time lift of the legacy app-group JSON blob into SQLite.
        LocalStore.importLegacyMessageBlobIfNeeded()

        // Render from disk before touching the network.
        applyLocalConversations()

        // Ensure Note to Self exists before the list is fetched, so it appears on first
        // launch rather than only after a second one. Idempotent server-side; a failure here
        // is not worth surfacing — the list still loads, and the next launch retries.
        _ = try? await ChatService.shared.createSelfChat()

        do {
            let convs = try await ChatService.shared.fetchConversations().map(LocalStore.applyingReadPosition)
            // Do not publish a partial classification if a community request fails.
            let communities = try await CommunityService.shared.mine()
            // /mine is capped at 200. Never classify from a potentially truncated list.
            guard communities.count < 200 else {
                throw NSError(domain: "GroupList", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn’t refresh groups from an incomplete community list."])
            }
            var channelIDs = Set<String>()
            for community in communities where community.isMember || community.owner_id == accountID {
                let channels = try await CommunityService.shared.channels(communityId: community.id)
                channelIDs.formUnion(channels.map(\.conversation_id))
            }
            guard TokenStore.shared.userId == accountID else { return }
            let hostIDs = ChatService.shared.lastHostThreadIDs
            hostThreadIDs = hostIDs
            let confirmed = Set(convs.filter { $0.type == .group && !channelIDs.contains($0.id) && !hostIDs.contains($0.id) }.map(\.id))
            // A group created while the fetch was in flight must survive this older snapshot.
            let newlyCreated = standaloneGroupIDs.subtracting(previousGroupIDs)
            LocalStore.saveConversations(convs)
            standaloneGroupIDs = confirmed.union(newlyCreated.subtracting(channelIDs).subtracting(hostIDs))
            communityChannelIDs = channelIDs
            // Learn the peer names/photos this payload carried, so calls and headers
            // can resolve a name without a further round trip. Bulk, not per-row: the
            // single-row upsert reloads the whole table and republishes each time.
            UserDirectory.shared.upsertManyFromServer(
                convs.compactMap { c in
                    guard c.type == .direct, let peer = c.peerUserId else { return nil }
                    return (userId: peer, fullName: c.title, username: nil, photoURL: c.photoURL)
                }
            )
            applyLocalConversations()
            loadError = nil
        } catch {
            // Only surface the failure if we have nothing to show. With cached
            // conversations on screen, a dropped connection is not worth an error
            // banner — the list is simply as fresh as the last successful sync.
            if directConversations.isEmpty && groupConversations.isEmpty && !SendRetry.isRetryable(error) {
                loadError = (error as? APIError)?.errorDescription ?? "Couldn’t load chats."
            } else {
                loadError = nil
            }
        }
        // Set on BOTH paths — success and failure. A load that failed is still a load that
        // finished; leaving this false would strand the user on a spinner forever with the
        // error banner hidden behind it.
        didLoadConversations = true
    }

    /// Publish whatever the local database currently holds.
    ///
    /// Previews are filled in from the local message store rather than being read from
    /// the conversations table: the offline list would otherwise render with no preview
    /// text at all, making a cold launch look emptier than it actually is even though
    /// every message is right there on disk.
    private func applyLocalConversations() {
        // Render the list STRAIGHT from SQLite: rows + denormalized last-message preview +
        // ordering, all from the conversations table. This touches NO message store — no whole
        // JSON decode, no per-conversation message load, no sorting — so the list paints
        // instantly and offline regardless of how much history exists. Each chat's full
        // message array is decoded lazily by openConversation(...) when it's actually opened
        // (WhatsApp-style). Previews stay fresh via bumpPreview at message-write time.
        let convs = LocalStore.conversations().map(LocalStore.applyingReadPosition)
        // Note to Self lives in CHATS, pinned to the top — it is the one conversation whose
        // position should never move, because you reach for it by muscle memory rather than
        // by recency. Filtering to `.direct` alone would have dropped it from both lists.
        let selfChats = convs.filter { $0.type == .self }
        directConversations = selfChats + convs.filter { $0.type == .direct }
        let channelIDs = communityChannelIDs
        // Host threads join the community channels here: still decryptable group sessions,
        // never rows in the Groups list.
        let hostIDs = hostThreadIDs
        communityConversations = convs.filter { $0.type == .group && (channelIDs.contains($0.id) || hostIDs.contains($0.id)) }
        let listedGroupIDs = standaloneGroupIDs.subtracting(hostIDs)
        groupConversations = convs.filter { $0.type == .group && listedGroupIDs.contains($0.id) }
        backfillPreviewsIfNeeded()
    }

    /// One-time backfill of last-message previews for chats that existed BEFORE previews were
    /// denormalized (the column is new). Runs OFF the launch-critical path (a low-priority
    /// task, after the list is already on screen) and only once — new activity keeps previews
    /// fresh from then on. No-op for fresh installs (nothing to backfill).
    private func backfillPreviewsIfNeeded() {
        // v2, not v1: every device that hit the bug already has v1 set to true, so the fixed
        // logic above would never get a chance to run there. Bumping the key is what actually
        // repairs the existing installs; the guard inside then keeps it to one real pass.
        let flag = "voiid.previews.backfilled.v2"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let ids = (directConversations + groupConversations).map { $0.id }
        Task(priority: .utility) {
            var wrote = 0
            var sawMessages = false
            for id in ids {
                guard let last = ChatEngine.shared.messages(conversationId: id).last else { continue }
                sawMessages = true
                let preview = !last.text.isEmpty ? last.text
                    : (last.media.map { $0.filename ?? ($0.mime.hasPrefix("audio/") ? "Voice message" : ($0.mime.hasPrefix("image/") || $0.mime.hasPrefix("video/") ? "Photo" : "Document")) } ?? "")
                if !preview.isEmpty {
                    LocalStore.updatePreview(conversationId: id, preview: preview, at: last.createdAt)
                    wrote += 1
                }
            }
            // ONLY BURN THE FLAG IF THERE WAS SOMETHING TO BACKFILL.
            //
            // This ran once, unconditionally, and set the flag whatever it found. But it
            // reads messages that are ALREADY DECRYPTED into the local store, and on the
            // launch where the column was new that store is often still empty — the first
            // sync has not finished. So it wrote nothing, marked itself done, and every
            // chat that existed before the column was added kept a blank preview forever,
            // with no path back: the flag guaranteed it would never look again.
            //
            // Keying on "did we actually see any messages" means an empty store leaves the
            // flag clear and the next launch retries, while a genuinely backfilled account
            // still runs exactly once.
            if sawMessages { UserDefaults.standard.set(true, forKey: flag) }
            if wrote > 0 { applyLocalConversations() }
        }
    }

    /// The transcript: real messages with this conversation's call bubbles merged in by time.
    ///
    /// Merging HERE rather than inserting into the message list keeps call logs out of the
    /// message store, the chat-list preview and the unread count, while every existing caller
    /// picks them up for free. No dummy seeding — a chat with nothing decrypted shows empty.
    /// The transcript: messages merged with call logs, in time order.
    ///
    /// MEMOISED, because this is read from SwiftUI body code and was doing a full merge and
    /// sort on every call — seven call sites in ChatDetailView alone, re-evaluated on every
    /// keystroke and every typing tick. The merge itself is cheap; running it dozens of
    /// times a second over a long thread is not.
    ///
    /// The `calls.isEmpty` fast path already avoided the sort for most 1:1 chats. This
    /// covers the rest: any conversation that has ever had a call in it.
    func messages(for id: String) -> [VMessage] {
        let msgs = messagesByConversation[id] ?? []
        let calls = callLogsByConversation[id] ?? []
        if calls.isEmpty { return msgs }

        let stamp = MergeStamp(messages: msgs.count, calls: calls.count,
                               newest: msgs.last?.createdAt)
        if let hit = mergeCache[id], hit.stamp == stamp { return hit.value }

        let merged = (msgs + calls).sorted { $0.createdAt < $1.createdAt }
        mergeCache[id] = (stamp, merged)
        return merged
    }

    // The published source dictionaries invalidate this cache on every mutation,
    // including status/reaction/call-outcome updates that preserve count and date.
    private struct MergeStamp: Equatable {
        let messages: Int
        let calls: Int
        let newest: Date?
    }
    /// Not @Published: it is derived state, and publishing it would invalidate every view
    /// that reads the transcript each time the cache filled — the opposite of the point.
    private var mergeCache: [String: (stamp: MergeStamp, value: [VMessage])] = [:]

    /// Load this conversation's call history into the transcript. Call on chat open, and again
    /// whenever a call ends so a call placed from this chat leaves its bubble immediately.
    func loadCallLogs(_ conversationId: String) {
        callLogsByConversation[conversationId] = LocalStore.callsForConversation(conversationId).map { r in
            let incoming = r.direction == "incoming"
            return VMessage(
                id: "call:\(r.id)",
                conversationId: conversationId,
                senderId: incoming ? (directConversations.first { $0.id == conversationId }?.peerUserId ?? "") : "me",
                kind: .call,
                text: "",
                createdAt: r.startedAt,
                isMine: !incoming,
                call: VCallLog(callId: r.id,
                               isVideo: r.kind == "video",
                               incoming: incoming,
                               outcome: r.outcome,
                               startedAt: r.startedAt,
                               endedAt: r.endedAt, connectedAt: r.connectedAt)
            )
        }
    }

    /// Start (or reopen) a 1:1 chat with a discovered contact. Creates the
    /// conversation server-side (idempotent), inserts it locally, and returns it
    /// so the caller can navigate into ChatDetail.
    func startDirectChat(with contact: VContact) async -> VConversation? {
        do {
            let convId = try await ChatService.shared.createDirect(memberId: contact.userId)
            if let existing = directConversations.first(where: { $0.id == convId }) {
                return existing
            }
            let conv = VConversation(id: convId, type: .direct, title: contact.displayName,
                                     photoName: nil, lastMessagePreview: nil, lastMessageAt: nil,
                                     unreadCount: 0, peerUserId: contact.userId, photoURL: contact.photoURL)
            // Persist before returning: a chat started here must still exist after a
            // restart even if no message is ever sent in it.
            LocalStore.upsertConversation(conv)
            directConversations.insert(conv, at: 0)
            return conv
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Couldn’t start chat."
            return nil
        }
    }

    /// Create a group conversation with `name` and the chosen contacts, insert it
    /// locally, and return it so the caller can navigate into it. Message E2E for
    /// groups (MLS) is a later increment — this wires the create + membership only.
    func createGroup(name: String, members: [VContact]) async -> VConversation? {
        do {
            let memberIds = members.map { $0.userId }
            let convId = try await ChatService.shared.createGroup(name: name, memberIds: memberIds)
            if let existing = groupConversations.first(where: { $0.id == convId }) {
                return existing
            }
            // Build the REAL MLS group on top of the server conversation: add each
            // member's device by KeyPackage and distribute Welcome/Commit.
            await GroupEngine.shared.createGroup(conversationId: convId, memberUserIds: memberIds)
            let conv = VConversation(id: convId, type: .group, title: name,
                                     photoName: nil, lastMessagePreview: nil, lastMessageAt: nil,
                                     unreadCount: 0, memberCount: members.count + 1)
            LocalStore.upsertConversation(conv)
            standaloneGroupIDs.insert(conv.id)
            groupConversations.insert(conv, at: 0)
            return conv
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Couldn’t create group."
            return nil
        }
    }

    /// The conversation currently ON SCREEN, or nil.
    ///
    /// Read receipts are gated on this. Without it `syncMessages` marked messages read from
    /// EVERY sync — including the one a background push triggers — so a message was reported
    /// "Seen" the moment it arrived in a chat the user had never opened. That is a privacy
    /// failure as much as a correctness one: it tells the sender you read something you have
    /// not looked at.
    private(set) var openConversationId: String? {
        // Mirrored to a process-global so the APP DELEGATE can read it.
        //
        // `willPresent` decides whether an arriving notification banners, and it runs on
        // AppDelegate — which cannot reach this store, since ChatStore is a per-view
        // @StateObject rather than a singleton. Rather than make it one (every call site
        // then has two ways to get at the same state, and they drift), the one field the
        // delegate needs is published here. Mirrors Android's AppPresence.
        didSet {
            ChatPresence.openConversationId = openConversationId
            // Opening a thread answers every banner pointing at it, so they go now rather
            // than waiting for the next foreground transition — the user is already reading
            // the thing they were being notified about. Mirrors Android's RootTabView hook.
            if UIApplication.shared.applicationState == .active, let id = openConversationId { MessageNotifications.clear(conversationId: id) }
        }
    }

    /// Open a conversation: show cached messages, then sync (fetch + decrypt-new) from server.
    func openConversation(_ conv: VConversation) {
        openConversationId = conv.id
        // Clear the badge NOW rather than waiting for the next /conversations poll. The
        // receipt round-trip takes a moment, and a chat you are staring at showing "3 unread"
        // is the single most obvious way for the count to look broken.
        ChatEngine.shared.queueConversationRead(conv.id)
        Task { await ChatEngine.shared.flushPendingReceipts() }
        if UIApplication.shared.applicationState == .active { clearUnreadLocally(conv.id) }
        refresh(conv.id)
        Task { await syncMessages(conv) }
    }

    /// Zero the local unread badge. The server is the source of truth; this just stops the
    /// UI lying during the round-trip.
    private func clearUnreadLocally(_ conversationId: String) {
        if let i = directConversations.firstIndex(where: { $0.id == conversationId }),
           directConversations[i].unreadCount != 0 {
            directConversations[i].unreadCount = 0
        }
        if let i = groupConversations.firstIndex(where: { $0.id == conversationId }),
           groupConversations[i].unreadCount != 0 {
            groupConversations[i].unreadCount = 0
        }
    }

    /// The chat closed. Stops read receipts for it until it is opened again.
    func closeConversation(_ conversationId: String) {
        if openConversationId == conversationId { openConversationId = nil }
    }

    /// Mark the open chat read. Called on open, and whenever a message lands WHILE it is
    /// open — the arrival path must not rely on the next manual sync.
    func markOpenConversationRead(_ conversationId: String) async {
        guard openConversationId == conversationId, UIApplication.shared.applicationState == .active else { return }
        await ChatEngine.shared.markRead(conversationId: conversationId)
    }

    /// Pull from the server and decrypt any new messages, then refresh the UI.
    func syncMessages(_ conv: VConversation) async {
        if conv.type == .group {
            // Groups: process MLS control events (Welcome/Commit) FIRST, then decrypt
            // this device's copy of the group's app messages into the shared store.
            await GroupEngine.shared.syncGroupEvents()
            await GroupEngine.shared.syncGroupMessages(conversationId: conv.id)
            // Only for the chat ON SCREEN — see `openConversationId`.
            await markOpenConversationRead(conv.id)
            refresh(conv.id)
            return
        }
        do {
            let peer = try await peerUserId(for: conv)
            _ = try await ChatEngine.shared.sync(conversationId: conv.id, peerUserId: peer)
            refresh(conv.id)
            // If we couldn't decrypt inbound messages, our session with the peer is
            // stale — ask them (once) to re-establish so future messages work.
            if ChatEngine.shared.lastSyncHadDecryptFailure, !resetRequested.contains(conv.id) {
                resetRequested.insert(conv.id)
                // Sessions are keyed per (peerUserId, deviceId) now — reset by peer, not conv.
                ChatEngine.shared.resetSession(peer)
                WebSocketClient.shared.sendSessionReset(conversationId: conv.id, recipientIds: [peer])
            }
            // Only for the chat ON SCREEN — see `openConversationId`.
            await markOpenConversationRead(conv.id)
            await fetchPresence(conv.id, peerUserId: peer)
        } catch {
            // Offline or a slow network is not an error to show: the thread on screen is as
            // fresh as the last sync, and the next one catches up by itself.
            if !SendRetry.isRetryable(error) {
                loadError = (error as? APIError)?.errorDescription ?? "Couldn’t load messages."
            }
            // MARK THE READ ANYWAY.
            //
            // Everything above can throw — resolving the peer, the fetch itself — and every
            // one of those throws used to skip the receipt, because it sat INSIDE the `do`.
            // The messages already on screen were still read by a human; a network failure
            // while re-syncing does not un-read them.
            //
            // That is what produced the reported symptom: an iOS device opens a chat, sees
            // an Android peer's message, hits any error on the sync, and then neither reports
            // the read (so the sender stays on Delivered forever) nor clears its own unread
            // badge (so the chat you are looking at still says unread).
            //
            // Safe to call on the error path: markRead only ever reports ids ALREADY in the
            // local store, and markOpenConversationRead still gates on the chat being open.
            await markOpenConversationRead(conv.id)
        }
    }

    /// Resolve the peer + refresh presence (for the periodic poll while a chat is open).
    func refreshPresence(_ conv: VConversation) async {
        guard conv.type == .direct, let peer = try? await peerUserId(for: conv) else { return }
        await fetchPresence(conv.id, peerUserId: peer)
    }

    /// Fetch + apply the peer's online/last-seen presence to the conversation.
    func fetchPresence(_ convId: String, peerUserId: String) async {
        let accountID = TokenStore.shared.userId
        let status = try? await ChatService.shared.status(userId: peerUserId)
        guard accountID == TokenStore.shared.userId,
              let i = directConversations.firstIndex(where: { $0.id == convId }) else { return }
        // Failed or hidden presence is unknown, never an indefinitely cached "Online".
        directConversations[i].isOnline = status?.online ?? false
        directConversations[i].lastSeenAt = status?.lastSeen
    }

    /// Apply a delivery/read receipt (WS) — persist it in the engine (no regression)
    /// then refresh that conversation.
    private func applyReceipt(messageId: String, status: String) {
        let cid = ChatEngine.shared.applyReceipt(messageId: messageId, status: status)
        NSLog("[VOIID] 📥 receipt \(status) for \(messageId) → \(cid == nil ? "no match" : "applied")")
        if let cid { refresh(cid) }
    }

    /// Rebuild a conversation's UI messages from the local (decrypted) store.
    private func refresh(_ convId: String) {
        var mapped = ChatEngine.shared.messages(conversationId: convId).compactMap { d -> VMessage? in
            // A location envelope: decode the stored (key-stripped) JSON into a LocationRef.
            // Rows in the location tables are RECONCILED from the message store here (the
            // store is the source of truth; the tables are a derived cache). pin / live_start
            // render a bubble; live_stop / live_rekey are SILENT control — recorded in the
            // decrypt-once ledger but never shown as a message (docs/LOCATION.md §4).
            let locRef: LocationRef?
            if let json = d.locationJSON, let env = LocationEnvelope.parse(json) {
                reconcileLocationShare(env, conversationId: convId, isMine: d.isMine, senderId: d.senderId)
                guard env.k.rendersBubble, env.k != .live_stop else { return nil }
                locRef = env.ref
            } else { locRef = nil }
            let kind: MessageKind
            if locRef != nil { kind = .location }
            else { kind = d.media.map { $0.filename != nil ? .document : ($0.mime.hasPrefix("audio/") ? .voice : ($0.mime.hasPrefix("image/") || $0.mime.hasPrefix("video/") ? .image : .document)) } ?? .text }
            // Mine: sending (offline) / sent / delivered / read — from the PERSISTED
            // delivery status so it never regresses on rebuild. Inbound: shown as read.
            let status: MessageStatus
            if d.isMine {
                if d.failed { status = .failed }
                else if d.pending { status = .sending }
                else {
                    switch d.deliveryStatus {
                    case "read": status = .read
                    case "delivered": status = .delivered
                    default: status = .sent
                    }
                }
            } else { status = .read }
            var vm = VMessage(id: d.serverId ?? d.id, conversationId: convId,
                              senderId: d.isMine ? "me" : d.senderId,
                              kind: kind, text: d.text, createdAt: d.createdAt,
                              status: status, isMine: d.isMine,
                              mediaRef: d.media, location: locRef)
            // Sender's real display name (saved name → full name → phone → username) for the
            // group bubble. Without this senderName stayed "" and the name never showed.
            if !d.isMine { vm.senderName = UserDirectory.shared.displayName(d.senderId) }
            // Real Delivered / Read times for the Message Info sheet (nil until each receipt).
            vm.deliveredAt = d.deliveredAt
            vm.readAt = d.readAt
            // Surface delivered chat actions onto the bubble.
            vm.deletedForEveryone = d.deletedForEveryone ?? false
            vm.forwarded = d.forwarded ?? false
            if let q = d.quotedPreview { vm.replyToText = q; vm.replyToSender = d.quotedSender }
            // Quoted moment (story reply). Carried through exactly like the quoted-message
            // snapshot above so the bubble treats the two as siblings; the thumbnail itself
            // is resolved from StoryStore inside the view, never cached onto the VM, because
            // the story can expire between one render and the next.
            if let sid = d.storyQuoteId {
                vm.storyQuoteId = sid
                vm.storyQuoteAuthorId = d.storyQuoteAuthorId
                vm.storyQuoteAt = d.storyQuoteCreatedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
                // A story REACTION is a body that is nothing but emoji — the quick-tap rail
                // sends `text: ""` with the emoji in `reaction`, and ChatEngine resolves the
                // body to that emoji. Detecting it by shape (rather than adding a wire flag)
                // keeps this working for Android senders too, whose envelope is identical.
                vm.isStoryReaction = VMessage.isSoloEmoji(d.text)
            }
            vm.reactions = d.reactions ?? [:]
            // A periodic sync must not overwrite a reaction still being sent.
            let key = ReactionKey(conversationId: convId, messageId: vm.id)
            if let pending = pendingReactions[key] {
                vm.reactions[pending.userId] = pending.emoji
            }
            if vm.deletedForEveryone { vm.reactions = [:] }
            return vm
        }
        mapped.append(contentsOf: pendingMediaMessages.values.filter { $0.conversationId == convId })
        mapped.sort { $0.createdAt < $1.createdAt }
        if !mapped.isEmpty || messagesByConversation[convId] != nil {
            messagesByConversation[convId] = mapped
        }
        if let last = mapped.last {
            let preview = (last.kind == .text || last.kind == .location) ? last.text : previewFor(last.kind)
            bumpPreview(convId, preview: preview)
        }
    }

    /// Keep the location tables in step with the message store: an INBOUND live_start creates
    /// the inbound-share row (so a relayed fix passes the client-side authorization check and
    /// its expiry is known), and a live_stop ends it. Outbound rows are owned by
    /// LocationShareEngine. Idempotent — runs on every refresh; the shareKey is already in the
    /// Keychain (captured at decrypt time), so no key handling is needed here.
    private func reconcileLocationShare(_ env: LocationEnvelope, conversationId: String,
                                        isMine: Bool, senderId: String) {
        guard !isMine, let shareId = env.s else { return }
        switch env.k {
        case .live_start:
            LocationStore.upsertInbound(id: shareId, conversationId: conversationId,
                                        ownerUserId: senderId, expiresAtMillis: env.expiresAt,
                                        cadenceSeconds: env.cadence ?? 15)
        case .live_stop:
            LocationStore.end(id: shareId)
            LocationShareEngine.shared.markStopped(shareId)
        default:
            break
        }
    }

    /// Encrypt attachment bytes, upload the ciphertext, and carry the key and optional
    /// document filename inside the direct or group encrypted message.
    func sendMedia(_ data: Data, mime: String, caption: String = "", filename: String? = nil, to conversationId: String) {
        let kind: MessageKind = filename != nil ? .document : (mime.hasPrefix("audio/") ? .voice : (mime.hasPrefix("image/") || mime.hasPrefix("video/") ? .image : .document))
        let tempId = UUID().uuidString
        let msg = VMessage(id: tempId, conversationId: conversationId, senderId: "me",
                           kind: kind, text: caption, createdAt: .now, status: .sending, isMine: true)
        let senderId = TokenStore.shared.userId
        pendingMediaMessages[tempId] = msg
        messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
        bumpPreview(conversationId, preview: previewFor(kind))

        let conv = directConversations.first(where: { $0.id == conversationId })
        let isGroup = encryptedGroupConversations.contains(where: { $0.id == conversationId })
        guard conv != nil || isGroup else {
            pendingMediaMessages[tempId]?.status = .failed
            refresh(conversationId)
            mediaSendError = "Media sending isn’t available in this conversation."
            return
        }
        // SLOW NETWORK IS NOT A FAILURE. A timeout, a dropped or system-cancelled request, or
        // a server hiccup keeps the bubble at "sending" ("Waiting for network" while offline)
        // and tries again in the background — 2s, 4s, 8s … up to a minute apart, and at once
        // when the connection returns — with the same id every time, so the server dedupes a
        // repeat whose reply was lost. Red is kept for a real refusal only.
        Task {
            var wait: Double = 2
            while true {
                do {
                    guard TokenStore.shared.userId == senderId, pendingMediaMessages[tempId] != nil else { return }
                    if isGroup {
                        try await GroupEngine.shared.sendGroupMedia(data, mime: mime, filename: filename,
                                                                   caption: caption, conversationId: conversationId,
                                                                   clientMessageId: tempId)
                    } else if let conv {
                        let peer = try await peerUserId(for: conv)
                        guard TokenStore.shared.userId == senderId, pendingMediaMessages[tempId] != nil else { return }
                        _ = try await ChatEngine.shared.sendMedia(data, mime: mime, caption: caption, filename: filename,
                                                                  conversationId: conversationId, peerUserId: peer,
                                                                  clientMessageId: tempId)
                    }
                    guard TokenStore.shared.userId == senderId, pendingMediaMessages[tempId] != nil else { return }
                    pendingMediaMessages[tempId] = nil
                    removeMessage(tempId, in: conversationId)
                    refresh(conversationId)
                    return
                } catch {
                    guard TokenStore.shared.userId == senderId, pendingMediaMessages[tempId] != nil else { return }
                    if SendRetry.isRetryable(error) {
                        NSLog("[VOIID] ⏳ media send will retry in \(Int(wait))s: \(error)")
                        await ChatNetwork.shared.wait(seconds: wait)
                        wait = min(wait * 2, 60)
                        continue
                    }
                    NSLog("[VOIID] ❌ media send gave up: \(error)")
                    failedMediaPayloads[tempId] = MediaPayload(data: data, mime: mime, caption: caption, filename: filename)
                    pendingMediaMessages[tempId]?.status = .failed
                    refresh(conversationId)
                    mediaSendError = SendRetry.message(for: error)
                    return
                }
            }
        }
    }

    /// Tap on a red "Failed": send it again. Media restarts from the bytes it kept; text goes
    /// back to the clock and is flushed now.
    func retryFailed(_ message: VMessage) {
        let conversationId = message.conversationId
        if let payload = failedMediaPayloads.removeValue(forKey: message.id) {
            pendingMediaMessages[message.id] = nil
            removeMessage(message.id, in: conversationId)
            sendMedia(payload.data, mime: payload.mime, caption: payload.caption,
                      filename: payload.filename, to: conversationId)
            return
        }
        ChatEngine.shared.clearFailed(localId: message.id, conversationId: conversationId)
        refresh(conversationId)
        guard let conv = directConversations.first(where: { $0.id == conversationId }) else { return }
        Task {
            guard let peer = try? await peerUserId(for: conv) else { return }
            await ChatEngine.shared.flushPending(conversationId: conversationId, peerUserId: peer)
            refresh(conversationId)
        }
    }

    /// Resolve (and cache) the peer user_id for a direct conversation.
    private func peerUserId(for conv: VConversation) async throws -> String {
        // NOTE TO SELF: the peer IS me. Without this case the generic path below asks
        // ChatService.resolvePeer for "the member who isn't me" — of a conversation whose only
        // member is me — gets nil, and throws 404 "no peer". That throw is why the whole
        // feature was dead: every send failed before it reached the fan-out that was already
        // written to handle this case correctly.
        if conv.type == .self { return TokenStore.shared.userId ?? "" }

        if let p = conv.peerUserId { return p }
        if let i = directConversations.firstIndex(where: { $0.id == conv.id }),
           let p = directConversations[i].peerUserId { return p }
        let resolved = try await ChatService.shared.resolvePeer(conversationId: conv.id)
        guard let peer = resolved.peerUserId else { throw APIError.http(status: 404, message: "no peer") }
        if let i = directConversations.firstIndex(where: { $0.id == conv.id }) {
            directConversations[i].peerUserId = peer
        }
        return peer
    }

    /// Send a real E2EE message in a direct chat (encrypt → /messages/send). Group
    /// chats keep a local echo only until MLS group messaging is wired.
    func send(_ text: String, kind: MessageKind = .text, to conversationId: String,
              replyTo: VMessage? = nil, forwarded: Bool = false) {
        let tempId = UUID().uuidString
        var msg = VMessage(id: tempId, conversationId: conversationId, senderId: "me",
                           kind: kind, text: text, createdAt: .now, status: .sending, isMine: true)
        msg.forwarded = forwarded
        if let r = replyTo {
            msg.replyToSender = r.isMine ? "You" : (r.senderName.isEmpty ? "" : r.senderName)
            msg.replyToText = r.kind == .text ? r.text : "Attachment"
        }
        guard let conv = directConversations.first(where: { $0.id == conversationId }) else {
            // Group conversation: real MLS end-to-end encryption.
            if kind == .text,
               encryptedGroupConversations.contains(where: { $0.id == conversationId }) {
                bumpPreview(conversationId, preview: text)
                Task {
                    do {
                        try await GroupEngine.shared.sendGroupMessage(conversationId: conversationId, text: text)
                        refresh(conversationId)
                    } catch where !SendRetry.isRetryable(error) {
                        loadError = (error as? APIError)?.errorDescription ?? "Couldn’t send the group message."
                    } catch {
                        NSLog("[VOIID] ⏳ group send waiting for network: \(error)")
                    }
                }
                return
            }
            // Unknown / non-text group payload — transient local echo only.
            messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
            bumpPreview(conversationId, preview: kind == .text ? text : previewFor(kind))
            markStatus(tempId, in: conversationId, to: .sent)
            return
        }

        guard kind == .text else {
            // Non-text via this path (rare, e.g. forwarded media) — transient echo.
            messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
            bumpPreview(conversationId, preview: previewFor(kind))
            return
        }

        // A quoted reply travels as its own E2EE envelope so the quote reaches the peer.
        if let r = replyTo {
            bumpPreview(conversationId, preview: text)
            let quotedId = r.id
            let preview = r.kind == .text ? String(r.text.prefix(80)) : previewFor(r.kind)
            let sender = r.isMine ? "You" : (r.senderName.isEmpty ? "" : r.senderName)
            Task {
                guard let peer = try? await peerUserId(for: conv) else {
                    // Offline: the message stays queued and goes when the connection returns.
                if ChatNetwork.shared.isReachable { loadError = "Couldn’t resolve the recipient." }
                return
                }
                _ = try? await ChatEngine.shared.sendReply(text: text, quotedId: quotedId,
                                                           quotedPreview: preview, quotedSender: sender,
                                                           conversationId: conversationId, peerUserId: peer)
                refresh(conversationId)
            }
            return
        }

        // Text: persist as PENDING in the engine store NOW (instant + offline-visible),
        // then flush (send) in the background. The store is the single source of truth.
        _ = ChatEngine.shared.enqueueText(text, conversationId: conversationId)
        refresh(conversationId)
        bumpPreview(conversationId, preview: text)
        Task {
            guard let peer = try? await peerUserId(for: conv) else {
                // Offline: the message stays queued and goes when the connection returns.
                if ChatNetwork.shared.isReachable { loadError = "Couldn’t resolve the recipient." }
                return
            }
            await ChatEngine.shared.flushPending(conversationId: conversationId, peerUserId: peer)
            refresh(conversationId)
        }
    }

    // MARK: - Realtime (WebSocket) glue

    private func removeTypingUser(_ userID: String, conversationID: String) {
        typingExpiry["\(conversationID):\(userID)"] = nil
        typingUsers[conversationID]?.remove(userID)
        if typingUsers[conversationID]?.isEmpty != false {
            typingUsers[conversationID] = nil
            typingConversations.remove(conversationID)
        }
    }

    private var realtimeInstalled = false
    private func startRealtime() {
        guard !realtimeInstalled else { return }
        realtimeInstalled = true
        ChatEngine.shared.onMessageStateChanged = { [weak self] cid in self?.refresh(cid) }
        WebSocketClient.shared.onMessageRef = { [weak self] cid in
            Task { await self?.handleIncoming(cid) }
        }
        WebSocketClient.shared.onTyping = { [weak self] cid, userID, isTyping in
            guard let self else { return }
            let key = "\(cid):\(userID)"
            self.typingExpiry[key]?.cancel()
            self.typingExpiry[key] = nil
            if isTyping {
                self.typingUsers[cid, default: []].insert(userID)
                self.typingConversations.insert(cid)
                let work = DispatchWorkItem { [weak self] in
                    self?.removeTypingUser(userID, conversationID: cid)
                }
                self.typingExpiry[key] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
            } else {
                self.removeTypingUser(userID, conversationID: cid)
            }
        }
        WebSocketClient.shared.onReceipt = { [weak self] mid, status in
            self?.applyReceipt(messageId: mid, status: status)
        }
        WebSocketClient.shared.onGroupEvent = { [weak self] cid in
            Task { await self?.handleGroupEvent(cid) }
        }
        WebSocketClient.shared.onSessionReset = { [weak self] cid in
            // Peer couldn't decrypt our messages → drop our session so the next send
            // re-establishes. Sessions are keyed per (peerUserId, deviceId) now, so resolve
            // the conversation's peer and reset across all of that peer's devices.
            guard let self else { return }
            Task {
                if let conv = self.directConversations.first(where: { $0.id == cid }),
                   let peer = try? await self.peerUserId(for: conv) {
                    ChatEngine.shared.resetSession(peer)
                }
            }
        }
        // Call signaling: wire the WebRTC engine's inbound handlers (call_offer/answer/
        // ice/hangup) + CallKit onto the same socket.
        CallService.shared.configure(socket: WebSocketClient.shared)
        // AND the conference engine, which owns `onCallKey`.
        //
        // This line was missing, and it was not a conference-only bug: `configure` is the
        // ONLY place `socket.onCallKey` is assigned (CallConference.swift:236), so inbound
        // `call_key` frames were dropped on the floor for every call, 1:1 included.
        //
        // The frame cryptor fails CLOSED by design (`discardFrameWhenCryptorNotReady: true`,
        // CallKeyExchange.swift:158) — the right choice, since the alternative is sending
        // media in the clear. But it meant the callee never received the per-call secret,
        // never attached a cryptor, and discarded every frame: calls reached "Connected"
        // with a running timer and SILENCE on both ends.
        //
        // It also left call_invite / call_migrate / accept / decline unhandled, so
        // escalating a 1:1 to a conference could never work over a live socket.
        CallConferenceService.shared.configure(socket: WebSocketClient.shared)
        // We're authenticated by the time realtime starts, so this is the point where
        // a VoIP token captured before login (or on a fresh install) gets uploaded.
        VoIPPushManager.shared.uploadTokenIfNeeded()
    }

    // Conversations we've already asked the peer to reset this session (avoid loops).
    private var resetRequested: Set<String> = []

    /// A message arrived (WS ref) — fetch + decrypt that conversation.
    private func handleIncoming(_ conversationId: String) async {
        NSLog("[VOIID] handleIncoming conv=\(conversationId) known=\(directConversations.contains { $0.id == conversationId })")
        if let conv = directConversations.first(where: { $0.id == conversationId })
            ?? encryptedGroupConversations.first(where: { $0.id == conversationId }) {
            await syncMessages(conv); return
        }
        // Unknown conversation (first message / a group we were just added to) — load the
        // list, THEN sync that conversation so the message actually appears (not just on open).
        await loadConversations()
        if let conv = directConversations.first(where: { $0.id == conversationId })
            ?? encryptedGroupConversations.first(where: { $0.id == conversationId }) {
            await syncMessages(conv)
        }
    }

    /// An MLS control event (Welcome/Commit) is waiting for us — process group events,
    /// then refresh any group we may have just joined. Triggered by the `mls_event` WS push.
    private func handleGroupEvent(_ conversationId: String) async {
        await GroupEngine.shared.syncGroupEvents()
        // A Welcome may have added us to a brand-new group not yet in our list.
        if !encryptedGroupConversations.contains(where: { $0.id == conversationId }) {
            await loadConversations()
        }
        if let conv = encryptedGroupConversations.first(where: { $0.id == conversationId }) {
            await syncMessages(conv)
        }
    }

    private func markStatus(_ id: String, in convId: String, to status: MessageStatus) {
        guard var arr = messagesByConversation[convId], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        arr[i].status = status
        messagesByConversation[convId] = arr
    }
    private func removeMessage(_ id: String, in convId: String) {
        messagesByConversation[convId]?.removeAll { $0.id == id }
    }

    private func previewFor(_ kind: MessageKind) -> String {
        switch kind {
        case .image: return "📷 Photo"
        case .voice: return "🎤 Voice message"
        case .document: return "📄 Document"
        default: return "Message"
        }
    }

    /// Forward a message to one or more conversations (with a Forwarded tag).
    /// Media is forwarded by RE-SENDING its existing E2EE reference — the ciphertext is
    /// already in R2, so no re-upload; the media key rides E2E as always.
    func forward(_ message: VMessage, to conversationIds: [String]) {
        for cid in conversationIds {
            if let ref = message.mediaRef, message.kind == .image || message.kind == .voice || message.kind == .document,
               let conv = directConversations.first(where: { $0.id == cid }) {
                Task {
                    guard let peer = try? await peerUserId(for: conv) else { return }
                    _ = try? await ChatEngine.shared.forwardMedia(ref, caption: message.text,
                                                                  conversationId: cid, peerUserId: peer)
                    refresh(cid)
                }
            } else {
                send(message.text,
                     kind: message.kind == .poll ? .text : message.kind,
                     to: cid, forwarded: true)
            }
        }
    }

    /// Delete a message. forEveryone=true tombstones it AND tells the peer to do the same;
    /// otherwise removes it only from this device.
    func deleteMessage(_ messageId: String, in convId: String, forEveryone: Bool) {
        deleteMessages([messageId], in: convId, forEveryone: forEveryone)
    }

    func deleteMessages(_ messageIds: Set<String>, in convId: String, forEveryone: Bool) {
        let rows = messages(for: convId).filter { messageIds.contains($0.id) }
        guard !rows.isEmpty else { return }
        let conv = directConversations.first { $0.id == convId }
        if forEveryone && (conv == nil || rows.contains(where: {
            !$0.isMine || $0.deletedForEveryone || $0.status == .sending || $0.status == .failed
        })) {
            deletionError = "Only your sent messages can be deleted for everyone."
            return
        }
        let keys = Set(rows.map { ReactionKey(conversationId: convId, messageId: $0.id) })
        guard deletingMessages.isDisjoint(with: keys) else { return }
        deletingMessages.formUnion(keys)
        let userId = TokenStore.shared.userId
        Task {
            defer { deletingMessages.subtract(keys) }
            do {
                if forEveryone, let conv {
                    let peer = try await peerUserId(for: conv)
                    for row in rows {
                        guard TokenStore.shared.userId == userId else { return }
                        try await ChatEngine.shared.sendDeleteForEveryone(targetServerId: row.id,
                            conversationId: convId, peerUserId: peer)
                    }
                } else {
                    try await ChatEngine.shared.deleteForMe(messageIds: Set(rows.map(\.id)), in: convId)
                    guard TokenStore.shared.userId == userId else { return }
                    for row in rows { pendingMediaMessages[row.id] = nil }
                    callLogsByConversation[convId]?.removeAll { messageIds.contains($0.id) }
                }
                guard TokenStore.shared.userId == userId else { return }
                refresh(convId)
                Haptics.rigid()
            } catch {
                guard TokenStore.shared.userId == userId else { return }
                refresh(convId)
                deletionError = "Couldn’t delete the message. Please try again."
            }
        }
    }

    /// Delete an entire conversation from the list.
    func deleteConversation(_ convId: String) {
        withAnimation {
            directConversations.removeAll { $0.id == convId }
            groupConversations.removeAll { $0.id == convId }
            messagesByConversation[convId] = nil
        }
        Haptics.rigid()
    }

    /// Clear all messages in a conversation but keep it in the list.
    func clearChat(_ convId: String) {
        deleteMessages(Set(messages(for: convId).map(\.id)), in: convId, forEveryone: false)
    }

    /// Pin or unpin a chat, and re-publish so the grid reorders immediately.
    ///
    /// Writes to SQLite FIRST and then republishes from it, rather than reordering the
    /// in-memory array and hoping the next refresh agrees. The grid is rebuilt from the
    /// database on every sync, so an arrangement that lives only in memory is discarded
    /// the moment anything refreshes — which is precisely the bug that made dragging a
    /// tile look like it worked and then silently snap back.
    func setPinned(_ convId: String, _ pinned: Bool) {
        // CLEAR THE MANUAL INDEX. A dragged arrangement writes a sort_index for every tile,
        // and that index is compared only among chats that share a pin state — so a chat
        // pinned afterwards kept the slot its old index described and appeared not to move.
        // Pinning is a statement about position, so it discards the position it replaces.
        LocalStore.setSortIndex(convId, nil)
        LocalStore.setPinned(convId, pinned)
        Haptics.tap()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            applyLocalConversations()
        }
    }

    /// Persist a manual arrangement from the grid's reorder mode.
    ///
    /// Deliberately does NOT re-publish afterwards. The grid has already animated the tiles
    /// into place, and rebuilding the list underneath a user who is still dragging would
    /// fight their own gesture. The next natural refresh reads the same order back.
    func setSortOrder(_ orderedIds: [String]) {
        // Every visible chat carries an index, pinned ones included — a pinned chat can be
        // rearranged among the other pins, so its position has to be storable too. The two
        // blocks never interleave because the query sorts pinned above unpinned first and
        // only then by this index, so one sequence describes both orders without ambiguity.
        LocalStore.setSortOrder(orderedIds)
    }

    /// Star or unstar a chat. Does not reorder — see LocalStore.setStarred.
    func setStarred(_ convId: String, _ starred: Bool) {
        LocalStore.setStarred(convId, starred)
        Haptics.tap()
        applyLocalConversations()
    }

    /// Optimistic, per-user reactions. Serialize sends per message so quick changes arrive
    /// in order, and retain the latest choice while sync rebuilds the transcript.
    func react(messageId: String, emoji: String, in convId: String) {
        guard let userId = TokenStore.shared.userId,
              let conv = directConversations.first(where: { $0.id == convId }),
              var arr = messagesByConversation[convId],
              let idx = arr.firstIndex(where: { $0.id == messageId }),
              !arr[idx].deletedForEveryone,
              arr[idx].status != .sending, arr[idx].status != .failed else { return }
        let key = ReactionKey(conversationId: convId, messageId: messageId)
        let pending = PendingReaction(userId: userId,
            emoji: MessageReactions.toggled(emoji, by: userId, in: arr[idx].reactions))
        pendingReactions[key] = pending
        arr[idx].reactions[userId] = pending.emoji
        // No transcript-wide spring: UIKit is dismissing the lifted message preview.
        messagesByConversation[convId] = arr
        Haptics.tap()
        let previous = reactionTasks[key]
        reactionTasks[key] = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, TokenStore.shared.userId == userId else { return }
            do {
                let peer = try await self.peerUserId(for: conv)
                try Task.checkCancellation()
                guard TokenStore.shared.userId == userId else { return }
                try await ChatEngine.shared.sendReaction(targetServerId: messageId,
                    emoji: pending.emoji, conversationId: convId, peerUserId: peer)
            } catch {
                guard !Task.isCancelled, TokenStore.shared.userId == userId else { return }
                if self.pendingReactions[key]?.id == pending.id {
                    self.reactionError = "Your reaction couldn’t be sent. Check your connection and try again."
                }
            }
            guard !Task.isCancelled, TokenStore.shared.userId == userId else { return }
            if self.pendingReactions[key]?.id == pending.id {
                self.pendingReactions[key] = nil
                self.reactionTasks[key] = nil
            }
            // Reads the last confirmed state on failure; preserves a newer pending choice.
            self.refresh(convId)
        }
    }

    /// Send a poll into a conversation.
    func sendPoll(_ question: String, options: [String], to conversationId: String) {
        let poll = VPoll(id: UUID().uuidString, question: question,
                         options: options.map { .init(id: UUID().uuidString, text: $0, votes: 0) })
        let msg = VMessage(id: UUID().uuidString, conversationId: conversationId, senderId: "me",
                           kind: .poll, text: "Poll", createdAt: .now, status: .sent, isMine: true, poll: poll)
        messagesByConversation[conversationId, default: messages(for: conversationId)].append(msg)
        bumpPreview(conversationId, preview: "📊 Poll: \(question)")
    }

    /// Register a vote on a poll option (single choice; toggles).
    func vote(messageId: String, optionId: String, in conversationId: String) {
        guard var arr = messagesByConversation[conversationId],
              let mi = arr.firstIndex(where: { $0.id == messageId }),
              var poll = arr[mi].poll else { return }
        for oi in poll.options.indices {
            if poll.options[oi].id == optionId { poll.options[oi].votes += 1 }
        }
        arr[mi].poll = poll
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            messagesByConversation[conversationId] = arr
        }
    }

    private func bumpPreview(_ convId: String, preview rawPreview: String) {
        // A game invite is a text message carrying `voiid:game/...` marker lines. Several callers
        // pass the message body straight through, so without this the chat LIST showed the raw
        // markers instead of a sentence — which is what "the invite message comes not properly"
        // looked like. Normalised HERE rather than at each call site: one place, every path.
        let preview = GameInvite.isInvite(rawPreview)
            ? GameInvite.preview(rawPreview)
            : rawPreview
        let now = Date()
        if let i = directConversations.firstIndex(where: { $0.id == convId }) {
            directConversations[i].lastMessagePreview = preview
            directConversations[i].lastMessageAt = now
        } else if let i = groupConversations.firstIndex(where: { $0.id == convId }) {
            groupConversations[i].lastMessagePreview = preview
            groupConversations[i].lastMessageAt = now
        }
        // Persist the snippet + time so the chat LIST renders it (and orders by it) on the
        // NEXT cold launch straight from SQLite — no message-store decode on the launch path.
        if !preview.isEmpty { LocalStore.updatePreview(conversationId: convId, preview: preview, at: now) }
    }
}

// MARK: - AI store
//
// REMOVED. Voiid AI is a real on-device assistant now — see Main/AI/AIModels.swift
// (`AIConversation`, streaming from Apple's Foundation Models) and Storage/AIStore.swift
// (persisted transcripts). The store here held three DummyData messages and answered every
// prompt with the same hardcoded sentence.

// MARK: - Clips store
//
// REMOVED. Clips are a real, server-backed feature now — see ClipsEngine (paging,
// uploads, optimistic-but-reconciled likes/comments) and ClipService. The old store
// here held DummyData arrays whose likes and comments were lost on every relaunch.

/// The one piece of chat UI state the app delegate needs, published where it can reach it.
///
/// `ChatStore` is a per-view `@StateObject`, so `AppDelegate.willPresent` — which decides
/// whether an arriving notification draws a banner — has no way to ask it what is on screen.
/// This holds the single field that decision needs and nothing else, so it cannot become a
/// second source of truth for anything.
///
/// Written only by `ChatStore.openConversationId`'s observer. Advisory: a stale value at
/// worst suppresses one banner for a chat just closed, which is a smaller failure than
/// bannering over a message the user is reading.
enum ChatPresence {
    nonisolated(unsafe) static var openConversationId: String?

    /// The chat grid's tile rectangles, in WINDOW coordinates, or empty when no grid is on
    /// screen.
    ///
    /// WHY A GEOMETRY TEST AND NOT ONLY A FLAG. `isReorderingGrid` is set when SwiftUI
    /// delivers the drag's first `onChanged`, and on a FAST flick UIKit has already asked
    /// its pan recogniser to begin before that arrives — so the flag was correct and still
    /// too late, and a quick sideways flick turned the page. Where a touch STARTED is known
    /// at the moment the question is asked, so it cannot lose that race.
    nonisolated(unsafe) static var gridTileFrames: [CGRect] = []

    /// True while the chat grid is in reorder mode.
    ///
    /// Read by TabSwipeNavigation's UIKit pan recogniser, which is why it lives here as a
    /// plain global rather than as view state: that recogniser is installed on the hosting
    /// controller and cannot see SwiftUI gestures at all. Without this the pager treats a
    /// sideways drag of a TILE as a sideways drag of the PAGE, so rearranging a chat into
    /// the next column changes tab instead — and the drag-to-Call and drag-to-Delete zones,
    /// which live at the left and right edges, are unreachable by construction.
    nonisolated(unsafe) static var isReorderingGrid = false
}

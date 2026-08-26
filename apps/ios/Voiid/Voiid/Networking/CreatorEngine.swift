//
//  CreatorEngine.swift
//  Voiid
//
//  Observable state for creator profiles, the follow graph, and the Following feed.
//  Transport lives in CreatorService; this owns the cache and the optimistic updates.
//
//  NOT E2EE — see the header of CreatorService.swift. A follow grants no messaging right.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class CreatorEngine: ObservableObject {
    private let svc = CreatorService.shared

    // MARK: - Your own profile (the gate)

    /// Your profile, or nil if you have none. `nil` is ambiguous on its own — it means
    /// both "not loaded yet" and "you have none" — so `hasLoadedMe` distinguishes them.
    /// Without that split the composer cannot tell a cold start from a genuine no-profile
    /// and would show the handle picker to someone who already has a handle.
    @Published private(set) var me: CreatorService.Profile?
    @Published private(set) var hasLoadedMe = false
    @Published private(set) var meLoading = false

    /// Whether the gate should open before posting. Answers false until `me` has actually
    /// loaded, so a slow network never fires a spurious picker.
    var needsProfile: Bool { hasLoadedMe && me == nil }

    @discardableResult
    func refreshMe() async -> CreatorService.Profile? {
        meLoading = true
        defer { meLoading = false }
        do {
            me = try await svc.me()
            hasLoadedMe = true
        } catch {
            // Deliberately does NOT set hasLoadedMe: a failed fetch is not evidence that the
            // user lacks a profile, and treating it as such would gate a creator out of
            // posting whenever the network blips.
            NSLog("[VOIID] creator me fetch failed: \(error.localizedDescription)")
        }
        return me
    }

    /// Ensures `me` is loaded, fetching only once. Called before the composer opens.
    @discardableResult
    func ensureMeLoaded() async -> CreatorService.Profile? {
        if hasLoadedMe { return me }
        return await refreshMe()
    }

    func createProfile(handle: String, displayName: String?, bio: String?,
                       linkURL: String?) async throws -> CreatorService.Profile {
        let p = try await svc.create(handle: handle, displayName: displayName,
                                     bio: bio, linkURL: linkURL)
        me = p
        hasLoadedMe = true
        cache[p.handle.lowercased()] = p
        return p
    }

    func updateProfile(handle: String? = nil, displayName: String? = nil,
                       bio: String? = nil, linkURL: String? = nil) async throws
        -> CreatorService.Profile {
        let old = me?.handle.lowercased()
        let p = try await svc.update(handle: handle, displayName: displayName,
                                     bio: bio, linkURL: linkURL)
        me = p
        // A rename leaves the old key pointing at a handle that no longer resolves.
        if let old, old != p.handle.lowercased() { cache.removeValue(forKey: old) }
        cache[p.handle.lowercased()] = p
        return p
    }

    /// Privacy settings. Separate from `updateProfile` deliberately: that one can carry a
    /// handle, and a handle change burns a 30-day rename window the server enforces. A
    /// privacy toggle must never be able to touch it by accident.
    func updatePrivacy(gridVisibility: String? = nil, showCounts: Bool? = nil,
                       discoverable: Bool? = nil, allowFollows: Bool? = nil,
                       allowComments: Bool? = nil) async throws {
        let p = try await svc.update(gridVisibility: gridVisibility, showCounts: showCounts,
                                     discoverable: discoverable, allowFollows: allowFollows,
                                     allowComments: allowComments)
        me = p
        cache[p.handle.lowercased()] = p
    }

    func uploadAvatar(jpeg: Data) async throws -> CreatorService.Profile {
        let p = try await svc.uploadAvatar(jpeg: jpeg)
        me = p
        cache[p.handle.lowercased()] = p
        return p
    }

    // MARK: - Handle availability

    /// Mirrors the server's HANDLE_RE. Checked client-side first so the obvious mistakes
    /// ("Ab", "1abc", "a-b") never cost a round-trip and the field can explain itself as
    /// the user types.
    static let handlePattern = "^[a-z][a-z0-9_]{2,19}$"

    static func isWellFormed(_ handle: String) -> Bool {
        handle.range(of: handlePattern, options: .regularExpression) != nil
    }

    enum HandleState: Equatable {
        case idle
        case checking
        case available
        case taken
        case badFormat
        case failed(String)
    }

    /// Debounced availability check. Each call cancels the in-flight one, so a fast typist
    /// issues one request at the end rather than one per keystroke — and, more importantly,
    /// a slow earlier response can never overwrite the answer for what is now in the field.
    private var handleCheckTask: Task<Void, Never>?

    func checkHandle(_ raw: String, debounce: Duration = .milliseconds(350),
                     into binding: @escaping (HandleState) -> Void) {
        handleCheckTask?.cancel()
        let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !handle.isEmpty else { binding(.idle); return }
        guard Self.isWellFormed(handle) else { binding(.badFormat); return }

        binding(.checking)
        handleCheckTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            do {
                let resp = try await self.svc.handleAvailable(handle)
                guard !Task.isCancelled else { return }
                if resp.available { binding(.available) }
                else { binding(resp.reason == "format" ? .badFormat : .taken) }
            } catch {
                guard !Task.isCancelled else { return }
                // Advisory only — a failed check must not block submission. The create call
                // re-validates under the real constraint anyway.
                binding(.failed("Couldn't check that handle."))
            }
        }
    }

    func cancelHandleCheck() {
        handleCheckTask?.cancel()
        handleCheckTask = nil
    }

    // MARK: - Public profiles

    /// Keyed on the lowercased handle. Small and short-lived: a profile carries a presigned
    /// avatar URL that expires, so this is a within-session convenience, not a store.
    @Published private(set) var cache: [String: CreatorService.Profile] = [:]

    func cachedProfile(_ handle: String) -> CreatorService.Profile? {
        cache[handle.lowercased()]
    }

    @discardableResult
    func loadProfile(_ handle: String) async throws -> CreatorService.Profile {
        let p = try await svc.profile(handle: handle)
        cache[p.handle.lowercased()] = p
        // The server is authoritative about whether this is you; keep `me` in step so an
        // edit made on another device shows up here.
        if p.is_self { me = p; hasLoadedMe = true }
        return p
    }

    // MARK: - Follow

    /// Optimistic: the button flips and the count moves immediately, then both are
    /// overwritten by the server's authoritative count. On failure the original state is
    /// restored — a follow button that lies about its state is worse than a slow one.
    func toggleFollow(_ handle: String) async {
        let key = handle.lowercased()
        guard var p = cache[key] else { return }
        let wasFollowing = p.following

        p.following = !wasFollowing
        // `map` so a HIDDEN count (nil) stays nil: bumping it would fabricate a number
        // the server deliberately withheld.
        p.follower_count = p.follower_count.map { max(0, $0 + (wasFollowing ? -1 : 1)) }
        cache[key] = p

        do {
            let resp = wasFollowing ? try await svc.unfollow(handle: handle)
                                    : try await svc.follow(handle: handle)
            if var updated = cache[key] {
                updated.following = resp.following
                updated.follower_count = resp.follower_count
                cache[key] = updated
            }
            // The set of people you follow changed, so the Following feed is stale.
            followingLoadedOnce = false
        } catch {
            if var reverted = cache[key] {
                reverted.following = wasFollowing
                reverted.follower_count = reverted.follower_count
                    .map { max(0, $0 + (wasFollowing ? 1 : -1)) }
                cache[key] = reverted
            }
        }
    }

    // MARK: - A creator's grid

    @Published private(set) var grids: [String: [CreatorService.CreatorClipRow]] = [:]
    private var gridCursors: [String: String?] = [:]
    private var gridLoading: Set<String> = []

    func clips(for handle: String) -> [CreatorService.CreatorClipRow] {
        grids[handle.lowercased()] ?? []
    }

    func refreshClips(for handle: String) async {
        let key = handle.lowercased()
        guard !gridLoading.contains(key) else { return }
        gridLoading.insert(key)
        defer { gridLoading.remove(key) }
        do {
            let resp = try await svc.clips(handle: handle)
            grids[key] = resp.clips
            gridCursors[key] = resp.next_cursor
        } catch {
            NSLog("[VOIID] creator clips failed for \(key): \(error.localizedDescription)")
        }
    }

    /// Keyset pagination, triggered by the tile near the end of the grid coming into view.
    func loadMoreClipsIfNeeded(handle: String, currentItem: CreatorService.CreatorClipRow) async {
        let key = handle.lowercased()
        guard let rows = grids[key], let cursor = gridCursors[key] ?? nil,
              !gridLoading.contains(key) else { return }
        // Prefetch a screenful early so the grid does not visibly stall at the bottom.
        guard rows.suffix(6).contains(where: { $0.id == currentItem.id }) else { return }

        gridLoading.insert(key)
        defer { gridLoading.remove(key) }
        do {
            let resp = try await svc.clips(handle: handle, cursor: cursor)
            // De-duplicated: a clip posted mid-scroll shifts the keyset window, and a
            // repeated id would crash a ForEach keyed on it.
            let existing = Set(rows.map(\.id))
            grids[key] = rows + resp.clips.filter { !existing.contains($0.id) }
            gridCursors[key] = resp.next_cursor
        } catch {
            NSLog("[VOIID] creator clips page failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Following feed

    @Published private(set) var following: [CreatorService.CreatorClipRow] = []
    @Published private(set) var followingLoading = false
    @Published private(set) var followingError: String?
    @Published private(set) var followingLoadedOnce = false
    private var followingCursor: String?

    func refreshFollowing() async {
        followingLoading = true
        followingError = nil
        defer { followingLoading = false }
        do {
            let resp = try await svc.followingFeed()
            following = resp.clips
            followingCursor = resp.next_cursor
            followingLoadedOnce = true
        } catch {
            followingError = error.localizedDescription
        }
    }

    func loadMoreFollowingIfNeeded(currentItem: CreatorService.CreatorClipRow) async {
        guard let cursor = followingCursor, !followingLoading,
              following.suffix(6).contains(where: { $0.id == currentItem.id }) else { return }
        followingLoading = true
        defer { followingLoading = false }
        do {
            let resp = try await svc.followingFeed(cursor: cursor)
            let existing = Set(following.map(\.id))
            following += resp.clips.filter { !existing.contains($0.id) }
            followingCursor = resp.next_cursor
        } catch {
            NSLog("[VOIID] following feed page failed: \(error.localizedDescription)")
        }
    }
}

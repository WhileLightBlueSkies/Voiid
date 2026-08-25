//
//  CommunityHomeTab.swift
//  Voiid
//
//  The Home tab inside a community — the admin dashboard, the pinned announcement and the
//  post feed. Ported from the reference's CommunityHomeScreen feed section.
//
//  ── WHAT IS REAL AND WHAT IS NOT ────────────────────────────────────────────────
//  POSTS and the ANNOUNCEMENT are live: GET /communities/:id/posts and
//  /communities/:id/announcements (047_community_home.sql). Both are SERVER-READABLE by
//  design — a post is a broadcast addressed to everyone who might later look, including
//  non-members of a discoverable community, and there is no key that means "everyone who
//  might later look". The channels themselves stay E2EE and are not touched here.
//
//  THE ADMIN DASHBOARD IS NOW REAL (053_community_moderation.sql). It used to read four
//  invented constants and a four-row fake queue, identical in every community — telling a host
//  with eleven members that they had 48.2K. Both halves are served now:
//
//    GET /communities/:id/stats ............. members (the trigger-maintained column, 030),
//                                             posts (a TRUE count over community_posts, never
//                                             the length of a feed page), and open reports.
//    GET /communities/:id/moderation-queue .. pending join requests (community_members.state =
//                                             'pending') and reported posts (content_reports,
//                                             target_type 'community_post'), merged newest
//                                             first, with the approve/reject buttons calling
//                                             /members/:userId/approve and /remove.
//
//  ── THREE STAT CARDS, NOT FOUR, AND THAT IS THE FEATURE ─────────────────────────
//  "Active today" is GONE rather than computed. Nothing in the schema records a per-user
//  last-seen, so it can only be faked — as a count of recent authors (a fraction of readers), a
//  count of recent joiners (growth wearing engagement's label), or a percentage (a made-up
//  number with a real one's precision). The server omits the key and this file renders what it
//  is given. A dashboard with three true numbers beats one with four of which a host cannot
//  tell which is the lie.
//
//  THE APPEARANCE IS UNCHANGED: same grid, same cards, same 58pt queue rows, same two circular
//  buttons. Only the data source moved, plus the buttons now do what they always looked like
//  they did.
//
//  AUTHORING (CommunityAuthoring.swift) hangs off this file: the compose bar above the feed,
//  Delete on a post's overflow menu, and the manager's pin/replace/unpin controls on the
//  announcement. All three call routes that already existed and had no caller. Every gate
//  drawn here is CONVENIENCE — the server decides identically whether or not a button was
//  drawn — and each one is commented with the route rule it mirrors.
//
//  The hero, identity, actions and tab bar live in CommunityDetailView — this file is only
//  what sits below the divider when Home is the selected tab.
//

import SwiftUI

struct CommunityHomeTab: View {
    let communityId: String
    /// Drives the admin dashboard. A member never renders it — the block is gated on the role
    /// rather than hidden behind a flag, so there is no build in which a member sees the queue.
    let isAdmin: Bool

    @State private var posts: [CommunityService.Post] = []
    @State private var pinned: CommunityService.Announcement?
    @State private var loading = true
    /// Non-nil ONLY when a fetch actually failed. Kept separate from "loaded and empty"
    /// because the two must never render the same: a failed feed that draws as an empty one
    /// tells the user their community has nothing in it, which is a lie the app has no way to
    /// take back.
    @State private var postsError: String?
    @State private var announcementError: String?
    /// Likes in flight, so a double-tap cannot fire two writes against one post.
    @State private var likeBusy: Set<String> = []

    /// The three authoring sheets. Separate booleans rather than one enum because they are
    /// presented from three different places and never contend.
    @State private var composing = false
    @State private var pinning = false
    /// The post the user asked to delete, held across the confirmation. Non-nil IS the alert's
    /// presented state — an `item:`-shaped flag, so the alert can never fire against a post
    /// that has since scrolled out of the array.
    @State private var pendingDelete: CommunityService.Post?
    /// The post being reported. Non-nil IS the sheet's presented state, so it can never fire
    /// against a post the feed has since reloaded away.
    @State private var reporting: CommunityService.Post?

    // ── The admin dashboard (053_community_moderation.sql) ───────────────────────
    // Both of these were `AdminStat.samples` and `AdminTask.samples` — invented constants and a
    // fake four-row queue, identical in every community.
    @State private var stats: CommunityService.Stats?
    @State private var queue: [CommunityService.QueueItem] = []
    @State private var adminLoading = false
    /// Non-nil ONLY when a fetch actually failed, and kept separate from an empty queue for the
    /// same reason `postsError` is: a moderation queue that failed to load and drew as empty
    /// would tell a host there is nothing waiting on them, which is the one lie a moderation
    /// surface must never tell.
    @State private var statsError: String?
    @State private var queueError: String?
    /// Queue rows with a write in flight, so a second tap cannot fire a duplicate approve.
    @State private var queueBusy: Set<String> = []
    /// Writes in flight, so a second tap cannot fire a duplicate delete or unpin.
    @State private var deleteBusy: Set<String> = []
    @State private var unpinBusy = false
    /// A failed WRITE, kept apart from `postsError` (a failed READ). The two say different
    /// things — one means "we couldn't show you the feed", the other "your post did not
    /// happen" — and a banner that conflated them would leave the user unsure which.
    @State private var writeError: String?

    /// Who this device is, for the author half of the delete gate. `TokenStore.shared.userId`
    /// is the same source `CommunityDetailView.isOwner` reads, so there is one answer on this
    /// screen to "who am I".
    private var myUserId: String? { TokenStore.shared.userId }

    var body: some View {
        VStack(spacing: VoiidSpacing.md) {
            // Admins get the numbers and the queue first. A member scrolling Home wants the
            // feed; an admin opening Home wants to know what needs them.
            if isAdmin { adminDashboard }

            announcement

            // Above the feed, below the announcement: the thing you came to say goes in at
            // the top of the list it lands at the top of.
            composeBar

            // A failed write is stated where the write was started from, and dismissible —
            // it is about one action that is now over, not about the state of the tab.
            if let writeError {
                HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(VoiidColor.error)
                    Text(writeError)
                        .font(VoiidFont.rounded(12.5))
                        .foregroundColor(VoiidColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        self.writeError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(VoiidSpacing.md - 2)
                .background(VoiidColor.error.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(VoiidColor.error.opacity(0.35), lineWidth: 1))
            }

            feed
        }
        .task { await load() }
        .sheet(isPresented: $composing) {
            CommunityPostComposer(communityId: communityId) { post in
                // The SERVER's row, prepended — not a locally-built one. It carries the id and
                // the author columns, so the card that appears is the card that will still be
                // there after the next refresh.
                posts.insert(post, at: 0)
                writeError = nil
            }
        }
        .sheet(isPresented: $pinning) {
            CommunityAnnouncementComposer(communityId: communityId,
                                          replacing: pinned != nil) { announcement in
                // ONE call replaced the old one server-side, in one transaction. Overwriting
                // the local slot mirrors exactly that; there is no second call to sequence.
                pinned = announcement
                announcementError = nil
                writeError = nil
            }
        }
        // Presented from HERE rather than from inside the card, for the same reason the delete
        // confirmation is: a sheet owned by a row in a lazy stack is torn down when that row
        // scrolls out of the stack, which can happen while the user is mid-report.
        .sheet(item: $reporting) { post in
            ReportSheet(target: .communityPost(postId: post.id)) { reporting = nil }
        }
        .alert("Delete this post?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { post in
            Button("Delete", role: .destructive) {
                Task { await deletePost(post) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            // Says what actually happens. 047 keeps the row so a moderator can see what they
            // removed and an appeal has something to point at; "deleted forever" would be a
            // promise the database does not make.
            Text("It is removed from the feed. Community moderators can still see that it "
                 + "existed and who removed it.")
        }
    }

    // MARK: Composing

    /// ANY ACTIVE MEMBER, not just a manager. `POST /:id/posts` gates on
    /// `communityAccess(id, user, false)` — the route's own comment says a discoverable
    /// community shows its feed to strangers so they can decide to join, which makes reading
    /// wider than writing and writing wider than managing. Drawing this admin-only would hide
    /// a member's own feed from them.
    ///
    /// This whole tab renders only inside `if c.isMember` in CommunityDetailView, so everyone
    /// who can see this bar can use it. The server still decides.
    private var composeBar: some View {
        Button {
            Haptics.tap()
            composing = true
        } label: {
            HStack(spacing: VoiidSpacing.sm + 2) {
                CommunityAvatar(name: "You", size: 32)

                Text("Share something\u{2026}")
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(VoiidColor.placeholder)

                Spacer(minLength: 0)

                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(VoiidColor.accent))
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.sm + 2)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Write a post")
    }

    /// May this device offer Delete on `post`?
    ///
    /// CONVENIENCE, NOT ENFORCEMENT. `DELETE /:id/posts/:postId` puts the ownership test in
    /// the WHERE clause of one UPDATE and answers a single 404 for "no such post", "already
    /// removed" and "not yours" alike — so a wrongly-drawn button fails safely and a wrongly-
    /// hidden one is only a missing affordance. This mirrors the route's rule (the author, OR
    /// a manager) so the menu item appears where it can actually succeed.
    private func canDelete(_ post: CommunityService.Post) -> Bool {
        if isAdmin { return true }
        guard let me = myUserId, let author = post.author_id else { return false }
        return me == author
    }

    /// Remove a post, optimistically — the same shape as `toggleLike` above: take it out
    /// immediately, put it back exactly where it was if the server refuses.
    ///
    /// The index is captured BEFORE the removal so a failure restores the post to its original
    /// position rather than to the top, which would silently reorder the feed as the cost of a
    /// failed delete.
    private func deletePost(_ post: CommunityService.Post) async {
        pendingDelete = nil
        guard !deleteBusy.contains(post.id) else { return }
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }

        deleteBusy.insert(post.id)
        defer { deleteBusy.remove(post.id) }

        let removed = posts.remove(at: index)
        writeError = nil

        do {
            try await CommunityService.shared.deletePost(communityId: communityId,
                                                         postId: post.id)
            Haptics.success()
        } catch {
            // Put it back. A post that vanished from a feed it is still in would have the user
            // believing they removed something they did not.
            Haptics.error()
            posts.insert(removed, at: min(index, posts.count))
            writeError = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t delete that post."
        }
    }

    /// Unpin the live announcement. Manager only (`requireManager` on the route).
    ///
    /// Optimistic like the rest: the card goes immediately and comes back on failure. Unpin
    /// sets `unpinned_at` — the row and its history survive, which is why the confirmation
    /// says "taken down", not "deleted".
    private func unpinAnnouncement(_ announcement: CommunityService.Announcement) async {
        guard !unpinBusy else { return }
        unpinBusy = true
        defer { unpinBusy = false }

        pinned = nil
        writeError = nil

        do {
            try await CommunityService.shared.unpinAnnouncement(
                communityId: communityId, announcementId: announcement.id)
            Haptics.success()
        } catch {
            Haptics.error()
            pinned = announcement
            writeError = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t unpin that announcement."
        }
    }

    // MARK: Loading

    /// Both reads in PARALLEL and each with its OWN error slot: the announcement and the feed
    /// are independent surfaces, and a community whose feed 500s should still show its pinned
    /// notice rather than losing the whole tab to one failure.
    private func load() async {
        loading = true
        defer { loading = false }

        async let feedTask = fetchPosts()
        async let pinnedTask = fetchAnnouncement()
        // The dashboard is fetched CONCURRENTLY with the feed, not after it: a host waiting on
        // twenty posts before their moderation queue appears is a host who stops checking it.
        //
        // The gate is convenience only. Both routes are `requireManager` server-side and would
        // 403 an ordinary member regardless of what this client believes — `isAdmin` here just
        // avoids firing two requests that are certain to be refused.
        async let adminTask: Void = isAdmin ? fetchAdmin() : ()
        _ = await (feedTask, pinnedTask, adminTask)
    }

    /// The dashboard's two reads.
    ///
    /// Independently faulted on purpose. The stats block and the queue fail for different
    /// reasons and a host must be able to tell which one did — a single shared error would let
    /// a working queue be hidden by a stats timeout, which on a moderation surface means real
    /// work going unseen.
    private func fetchAdmin() async {
        adminLoading = true
        defer { adminLoading = false }

        async let statsTask = fetchStats()
        async let queueTask = fetchQueue()
        _ = await (statsTask, queueTask)
    }

    private func fetchStats() async {
        do {
            stats = try await CommunityService.shared.stats(communityId: communityId)
            statsError = nil
        } catch {
            // The previous numbers are DISCARDED rather than left on screen. Stale stats
            // presented as current are the same failure the invented ones were, only harder to
            // spot because they were true an hour ago.
            stats = nil
            statsError = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t load these numbers."
        }
    }

    private func fetchQueue() async {
        do {
            queue = try await CommunityService.shared.moderationQueue(communityId: communityId)
            queueError = nil
        } catch {
            queue = []
            queueError = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t load what needs you."
        }
    }

    /// Act on one queue row.
    ///
    /// ── WHAT EACH BUTTON ACTUALLY DOES ──────────────────────────────────────────────
    ///   join request, tick .... POST /members/:userId/approve — pending becomes active.
    ///   join request, cross ... POST /members/:userId/remove — pending becomes left.
    ///                           DELIBERATELY `remove` AND NOT `ban`. The server keeps them as
    ///                           separate verbs so the harsher one is chosen on purpose, and a
    ///                           rejected applicant can ask again — the right default for
    ///                           someone whose only act so far was knocking.
    ///   reported post, tick ... clears the row locally. There is NO "dismiss report" route:
    ///                           resolving a content_report is a platform-admin action
    ///                           (035 gives `resolved_by` a `admin_users` foreign key), not a
    ///                           community host's. See the note below.
    ///   reported post, cross .. removes the post, the same route the card's own Delete uses.
    private func resolveQueueItem(_ item: CommunityService.QueueItem, approve: Bool) async {
        guard !queueBusy.contains(item.id) else { return }
        queueBusy.insert(item.id)
        defer { queueBusy.remove(item.id) }

        do {
            switch item.resolvedKind {
            case .joinRequest:
                guard let userId = item.user_id else { return }
                if approve {
                    try await CommunityService.shared.approveMember(
                        communityId: communityId, userId: userId)
                } else {
                    try await CommunityService.shared.removeMember(
                        communityId: communityId, userId: userId)
                }

            case .reportedPost:
                guard let postId = item.post_id else { return }
                if approve {
                    // ── AN HONEST LIMITATION, NOT A SILENT ONE ──────────────────────
                    // "Keep this post" clears the row from THIS host's view and nothing more.
                    // The open content_reports rows survive, because marking a report resolved
                    // is bound to an `admin_users` row (035) and a community host is not one.
                    // Building a host-side resolve would mean either widening `resolved_by`
                    // past the admin table or adding a parallel per-community resolution
                    // state — both are moderation-authority decisions, not details to settle
                    // inside a button handler.
                    //
                    // The row therefore returns on the next refresh. That is the truthful
                    // behaviour: the report IS still open. Nothing here claims otherwise.
                    Haptics.tap()
                } else {
                    try await CommunityService.shared.deletePost(
                        communityId: communityId, postId: postId)
                    // Take it out of the feed too, if it is on screen. Leaving a removed post
                    // rendered above the dashboard that just removed it is the kind of
                    // disagreement that makes a host doubt the button worked.
                    posts.removeAll { $0.id == postId }
                }

            case .none:
                return
            }

            queue.removeAll { $0.id == item.id }
            // The badge and the "Needs review" card are counts of the same work, so the numbers
            // are refetched rather than decremented locally — the server's count is the one
            // that survives a pull-to-refresh, and a local guess would disagree with it.
            await fetchStats()
            Haptics.success()
        } catch {
            // THE ROW STAYS. A queue item that vanishes on a failed write tells a host the work
            // is done when it is not, and there is nothing left on screen to retry from.
            Haptics.error()
            queueError = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t do that. Try again."
        }
    }

    private func fetchPosts() async {
        do {
            posts = try await CommunityService.shared.posts(communityId: communityId).rows
            postsError = nil
        } catch {
            postsError = (error as? APIError)?.errorDescription ?? "Couldn\u{2019}t load posts."
        }
    }

    private func fetchAnnouncement() async {
        do {
            pinned = try await CommunityService.shared.announcement(communityId: communityId)
            announcementError = nil
        } catch {
            announcementError = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t load the announcement."
        }
    }

    /// Optimistic, then reconciled against the server's count.
    ///
    /// The server moves `like_count` only when the join row actually moved, so its number is
    /// the one that converges under a retry or a double-tap. The local flip is only there so
    /// the heart does not wait for a round trip; the server's answer overwrites it, and a
    /// failure puts the row back exactly as it was.
    private func toggleLike(_ post: CommunityService.Post) async {
        guard !likeBusy.contains(post.id) else { return }
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }

        likeBusy.insert(post.id)
        defer { likeBusy.remove(post.id) }

        let wasLiked = post.isLiked
        let previousCount = post.likes
        posts[index].liked_by_me = !wasLiked
        posts[index].like_count = max(previousCount + (wasLiked ? -1 : 1), 0)

        do {
            let result = wasLiked
                ? try await CommunityService.shared.unlikePost(communityId: communityId, postId: post.id)
                : try await CommunityService.shared.likePost(communityId: communityId, postId: post.id)
            guard let now = posts.firstIndex(where: { $0.id == post.id }) else { return }
            posts[now].liked_by_me = result.liked ?? !wasLiked
            posts[now].like_count = result.like_count ?? posts[now].like_count
        } catch {
            // Put it back. A heart that stayed filled after a failed write would be the app
            // showing a like that does not exist.
            guard let now = posts.firstIndex(where: { $0.id == post.id }) else { return }
            posts[now].liked_by_me = wasLiked
            posts[now].like_count = previousCount
        }
    }

    // MARK: Feed

    /// FOUR DISTINCT STATES, and the third and fourth are the ones that matter: a failed fetch
    /// says so and offers a retry, while a genuinely empty feed says the community has not
    /// posted. Collapsing them would make every outage look like an empty community.
    @ViewBuilder
    private var feed: some View {
        if loading && posts.isEmpty {
            ProgressView().tint(VoiidColor.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, VoiidSpacing.lg)
        } else if let postsError, posts.isEmpty {
            emptyish(icon: "exclamationmark.triangle", title: postsError,
                     detail: "Pull down to try again.")
        } else if posts.isEmpty {
            emptyish(icon: "square.and.pencil", title: "No posts yet",
                     detail: isAdmin ? "Post something to get the feed started."
                                     : "Nothing has been posted here yet.")
        } else {
            ForEach(posts) { post in
                CommunityPostCard(
                    post: post,
                    // Nil hides the menu item entirely rather than disabling it: a greyed
                    // Delete on somebody else's post is an invitation to wonder why.
                    onDelete: canDelete(post) ? { pendingDelete = post } : nil,
                    onLike: { Task { await toggleLike(post) } },
                    onReport: { reporting = post }
                )
                // The row is mid-delete: dimmed and inert, so a second tap cannot start a
                // duplicate write against a post that is already on its way out.
                .opacity(deleteBusy.contains(post.id) ? 0.45 : 1)
                .allowsHitTesting(!deleteBusy.contains(post.id))
            }
        }
    }

    // MARK: Admin dashboard

    /// Four numbers and the queue of things waiting on a decision.
    ///
    /// Deliberately ON Home rather than behind a separate "Admin" tab: moderation that lives
    /// somewhere else gets checked when someone remembers to, and a report sitting unread for
    /// a day is how a community goes bad.
    private var adminDashboard: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm + 2) {
            HStack {
                Text("Admin overview")
                    .font(VoiidFont.rounded(15, .bold))
                    .foregroundColor(VoiidColor.textPrimary)

                Spacer(minLength: 0)

                Text("Host")
                    .font(VoiidFont.rounded(10, .bold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(VoiidColor.accent))
            }

            // THE SAME TWO-COLUMN GRID, THE SAME CARDS. Only the source changed: these are
            // counts over real tables now (GET /communities/:id/stats) instead of four
            // constants that told a host with eleven members they had 48.2K.
            //
            // THREE CARDS, NOT FOUR, and the missing one is "Active today". Nothing in the
            // schema records a per-user last-seen, so it is not computable — and the three ways
            // to fake it (count recent authors, count recent joiners, take a percentage of the
            // member count) each produce a number that looks precise and is wrong. 053's header
            // works through each. The server omits the key; this renders what it is given, so
            // there is no build in which a guess appears here.
            if let stats {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(statCards(stats)) { stat in
                        statCard(stat)
                    }
                }
            } else if let statsError {
                // A failed fetch says so. It must never draw as zeroes — a dashboard reading
                // "0 posts" because the request timed out is the same class of lie the invented
                // numbers were.
                emptyish(icon: "exclamationmark.triangle", title: statsError,
                         detail: "Pull down to try again.")
            } else if adminLoading {
                ProgressView().tint(VoiidColor.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, VoiidSpacing.md)
            }

            // "Needs you" appears only when something actually is. An empty queue draws
            // NOTHING, exactly as the placeholder did when its array was empty — a "nothing to
            // do" card would be a permanent fixture on every healthy community's dashboard.
            if let queueError {
                HStack {
                    Text("Needs you")
                        .font(VoiidFont.rounded(15, .bold))
                        .foregroundColor(VoiidColor.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.top, VoiidSpacing.sm)

                emptyish(icon: "exclamationmark.triangle", title: queueError,
                         detail: "Pull down to try again.")
            } else if !queue.isEmpty {
                HStack {
                    Text("Needs you")
                        .font(VoiidFont.rounded(15, .bold))
                        .foregroundColor(VoiidColor.textPrimary)

                    Text("\(queue.count)")
                        .font(VoiidFont.rounded(10.5, .bold))
                        .foregroundColor(VoiidColor.textOnAccent)
                        .frame(minWidth: 19, minHeight: 19)
                        .background(Circle().fill(VoiidColor.accent))

                    Spacer(minLength: 0)
                }
                .padding(.top, VoiidSpacing.sm)

                VStack(spacing: 8) {
                    ForEach(queue) { item in
                        taskRow(item)
                            .opacity(queueBusy.contains(item.id) ? 0.45 : 1)
                            .allowsHitTesting(!queueBusy.contains(item.id))
                    }
                }
            }
        }
        .padding(.bottom, VoiidSpacing.sm)
    }

    /// The stat cards, built from what the server actually sent.
    ///
    /// EVERY ONE OF THESE IS A COUNT OF ROWS. There is no derived, estimated or extrapolated
    /// number here, and there is no `delta` that was not computed — which is why `delta` is
    /// empty on all three.
    ///
    /// ── WHY NO "+312 THIS WEEK" ─────────────────────────────────────────────────────
    /// The placeholder's cards each carried a trend line. A trend needs a PREVIOUS value to
    /// compare against, and nothing stores one: there are no historical snapshots of a
    /// community's member or post count, so "+312 this week" could only ever be invented. The
    /// arrow and its label are therefore absent — `statCard` already renders an empty delta as
    /// no row at all, so the card is shorter rather than wrong.
    private func statCards(_ s: CommunityService.Stats) -> [AdminStat] {
        [
            .init(id: "members", label: "Members", value: "\(s.memberCount)", delta: "",
                  icon: "person.2.fill"),
            .init(id: "posts", label: "Posts", value: "\(s.postCount)", delta: "",
                  icon: "square.and.pencil"),
            // `isPositive: false` is the placeholder's own convention for this card and it is
            // kept: it drives the warning tint and the exclamation glyph, so open reports never
            // render as good news with an up arrow.
            .init(id: "reports", label: "Needs review", value: "\(s.openReports)", delta: "",
                  icon: "exclamationmark.triangle.fill", isPositive: false),
        ]
    }

    private func statCard(_ stat: AdminStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: stat.icon)
                    .font(.system(size: 12))
                    .foregroundColor(stat.isPositive ? VoiidColor.accentInk : VoiidColor.warning)
                Text(stat.label)
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)
                Spacer(minLength: 0)
            }

            Text(stat.value)
                .font(VoiidFont.rounded(21, .bold))
                .foregroundColor(VoiidColor.textPrimary)
                .monospacedDigit()

            // The delta row is drawn ONLY when there is a delta. It used to be unconditional
            // because the samples always carried one; every real stat carries none, because no
            // historical snapshot exists to compare against and a trend nobody measured is not
            // a trend. An empty delta is a shorter card, not a card with a blank arrow.
            if !stat.delta.isEmpty {
                HStack(spacing: 3) {
                    // Direction AND colour. Hue alone would fail for a colour-blind admin.
                    Image(systemName: stat.isPositive ? "arrow.up.right"
                                                      : "exclamationmark.circle")
                        .font(.system(size: 9, weight: .bold))
                    Text(stat.delta)
                        .font(VoiidFont.rounded(10.5))
                }
                .foregroundColor(stat.isPositive ? VoiidColor.success : VoiidColor.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiidSpacing.sm + 2)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }

    /// One row of the real moderation queue.
    ///
    /// THE LAYOUT IS UNCHANGED from the placeholder — same 58pt row, same 34pt glyph tile, same
    /// two circular buttons on the right. What changed is that the buttons now call routes.
    ///
    /// ── THE TWO KINDS DO DIFFERENT THINGS, AND THE LABELS SAY SO ────────────────────
    /// A join request approves or rejects a PERSON (`/members/:userId/approve` and `/remove`).
    /// A reported post has no equivalent pair — approving a person is not a thing you can do to
    /// a post — so its tick means "this post is fine, clear it" and its cross opens the delete
    /// path the card's own menu uses. Giving both kinds the same two glyphs with different
    /// meanings is a real hazard, which is why the accessibility labels differ per kind rather
    /// than being one shared string.
    private func taskRow(_ item: CommunityService.QueueItem) -> some View {
        let isReport = item.resolvedKind == .reportedPost
        return HStack(spacing: VoiidSpacing.sm + 2) {
            Image(systemName: isReport ? "flag.fill" : "person.badge.plus")
                .font(.system(size: 13))
                .foregroundColor(isReport ? VoiidColor.warning : VoiidColor.accentInk)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isReport ? VoiidColor.warning.opacity(0.14) : VoiidColor.accentTint))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                Text(taskDetail(item))
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(CommunityFeedDate.age(item.at))
                .font(VoiidFont.rounded(10.5))
                .foregroundColor(VoiidColor.textSecondary)

            // Both answers on the row. A queue where acting means opening each item is a queue
            // that does not get cleared.
            HStack(spacing: 6) {
                Button {
                    Task { await resolveQueueItem(item, approve: true) }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(VoiidColor.textOnAccent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(VoiidColor.accent))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(isReport ? "Keep this post" : "Approve")

                Button {
                    Task { await resolveQueueItem(item, approve: false) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(VoiidColor.surfaceRaised))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(isReport ? "Remove this post" : "Reject")
            }
        }
        .padding(.horizontal, VoiidSpacing.sm + 2)
        .frame(height: 58)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isReport ? "Reported post" : "Join request"): "
                            + "\(item.name), \(taskDetail(item))")
    }

    /// The row's second line. Says what is actually known and nothing more.
    private func taskDetail(_ item: CommunityService.QueueItem) -> String {
        switch item.resolvedKind {
        case .joinRequest:
            // The handle when the server sent one — a null `username` is a real row (a user who
            // never set one), not a defect, so the line degrades rather than showing "@".
            if let u = item.username, !u.isEmpty { return "Wants to join · @\(u)" }
            return "Wants to join"
        case .reportedPost:
            let n = item.reporter_count ?? 0
            // "3 members reported this" is a count of DISTINCT REPORTERS, which is what the
            // server sends and what the sentence claims. Counting report rows instead would
            // let one person's repeat reports inflate it — the thing 035's partial unique index
            // exists to prevent.
            let who = n == 1 ? "1 member reported this" : "\(n) members reported this"
            if let excerpt = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !excerpt.isEmpty {
                return "\(who) · \(excerpt)"
            }
            return who
        case .none:
            // A kind this build does not know. Never guessed at — the row still renders with
            // its subject and time so it is visibly present rather than silently dropped.
            return "Needs review"
        }
    }

    // MARK: Announcement

    /// Three states, in the same card. Nothing pinned renders NOTHING — an empty pinned-card
    /// with placeholder text would be the app inventing a notice the host never wrote — and a
    /// failed fetch says so rather than silently looking like "nothing pinned".
    /// A FOURTH state was added for managers only: nothing pinned AND you are allowed to pin.
    /// A member still sees nothing, because for them "nothing pinned" remains a fact with no
    /// action attached — the routes are `requireManager` in both directions.
    @ViewBuilder
    private var announcement: some View {
        if let pinned {
            // The card itself is UNCHANGED. The manager's controls sit BELOW it as their own
            // row rather than inside it, so the reading experience is byte-for-byte what it
            // was and the authoring is an addition rather than an edit.
            announcementCard(pinned)

            if isAdmin {
                HStack(spacing: VoiidSpacing.sm) {
                    announcementControl("Replace", icon: "arrow.triangle.2.circlepath") {
                        pinning = true
                    }
                    announcementControl("Unpin", icon: "pin.slash") {
                        Task { await unpinAnnouncement(pinned) }
                    }
                    Spacer(minLength: 0)
                }
                .opacity(unpinBusy ? 0.5 : 1)
                .allowsHitTesting(!unpinBusy)
            }
        } else if let announcementError, !loading {
            emptyish(icon: "exclamationmark.triangle", title: announcementError,
                     detail: "Pull down to try again.")
        } else if isAdmin && !loading {
            // Nothing pinned, and this person can fix that. Deliberately NOT a fake card with
            // placeholder text — that would be the app inventing a notice the host never
            // wrote. It is an empty slot that says what it is for.
            Button {
                Haptics.tap()
                pinning = true
            } label: {
                HStack(spacing: VoiidSpacing.sm + 2) {
                    Image(systemName: "pin")
                        .font(.system(size: 14))
                        .foregroundColor(VoiidColor.accentInk)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(VoiidColor.accentTint))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Pin an announcement")
                            .font(VoiidFont.rounded(14, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                        Text("It sits at the top of Home for everyone.")
                            .font(VoiidFont.rounded(11.5))
                            .foregroundColor(VoiidColor.textSecondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(VoiidColor.textSecondary)
                }
                .padding(VoiidSpacing.md - 2)
                .background(VoiidColor.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                        // Dashed, so an empty slot never reads as a real pinned notice at a
                        // glance the way a solid card would.
                        .strokeBorder(VoiidColor.divider,
                                      style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    /// One of the manager's two announcement actions. A small capsule rather than a full-width
    /// button: these act on the card above them and should not outweigh it.
    private func announcementControl(_ title: String, icon: String,
                                     action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(VoiidFont.rounded(12.5, .semibold))
            }
            .foregroundColor(VoiidColor.accentInk)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(Capsule().fill(VoiidColor.surfaceCard))
            .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func announcementCard(_ pinned: CommunityService.Announcement) -> some View {
        Button {
            Haptics.tap()
        } label: {
            HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundColor(VoiidColor.accentInk)
                        Text("Pinned Announcement")
                            .font(VoiidFont.rounded(12, .semibold))
                            .foregroundColor(VoiidColor.accentInk)
                    }

                    Text(pinned.headline)
                        .font(VoiidFont.rounded(14.5, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .multilineTextAlignment(.leading)

                    Text(pinned.text)
                        .font(VoiidFont.rounded(13))
                        .foregroundColor(VoiidColor.textSecondary)
                        .multilineTextAlignment(.leading)

                    Text("By \(pinned.displayName) · \(CommunityFeedDate.age(pinned.pinned_at))")
                        .font(VoiidFont.rounded(11.5))
                        .foregroundColor(VoiidColor.textSecondary.opacity(0.8))
                        .padding(.top, 1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(.top, 2)
            }
            .padding(VoiidSpacing.md)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                    .stroke(VoiidColor.divider, lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Feed timestamps

/// "2h ago" for the feed, from the server's ISO-8601 timestamp.
///
/// NOT `VoiidDate.relative`, and the difference is deliberate: that helper is chat phrasing
/// ("today at 9:41 AM", "yesterday") which is right beside a message bubble and wrong under a
/// post author's name, where the reference reads "2h ago". Same clock, different sentence.
///
/// A timestamp that fails to parse renders as an EMPTY string rather than "now" or a fallback
/// date — a wrong age is worse than no age, because the reader has no way to tell it is wrong.
enum CommunityFeedDate {
    private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // Postgres timestamptz serialises with fractional seconds; the bare parser below picks
        // up the ones that do not. Both spellings arrive from this API.
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()

    static func age(_ iso: String?) -> String {
        guard let iso,
              let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        else { return "" }

        let secs = Date().timeIntervalSince(date)
        // A clock-skewed future timestamp reads as "now" rather than as a negative age.
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86_400 { return "\(Int(secs / 3600))h ago" }
        if secs < 604_800 { return "\(Int(secs / 86_400))d ago" }
        return day.string(from: date)
    }
}

// MARK: - A post

private struct CommunityPostCard: View {
    let post: CommunityService.Post
    /// NIL WHEN THIS DEVICE CANNOT DELETE THIS POST, and the menu item is then not drawn at
    /// all. The parent decides (author or manager, mirroring the route); the card only renders
    /// what it was handed, so there is one place that knows the rule.
    var onDelete: (() -> Void)?
    /// Fired by the heart. The parent owns the optimistic flip and the reconciliation, so this
    /// card stays a pure render of whatever it was handed.
    let onLike: () -> Void
    /// Fired by Report. The parent presents the sheet, for the same reason it owns the delete
    /// confirmation: a sheet presented from inside a row in a lazy stack is a sheet that can be
    /// torn down mid-interaction when the row scrolls out.
    let onReport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(spacing: 9) {
                CommunityAvatar(name: post.displayName, size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(post.displayName)
                        .font(VoiidFont.rounded(14, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    Text(CommunityFeedDate.age(post.created_at))
                        .font(VoiidFont.rounded(11.5))
                        .foregroundColor(VoiidColor.textSecondary)
                }

                Spacer(minLength: 0)

                Menu {
                    Button("Save post", systemImage: "bookmark") {}
                    Button("Share", systemImage: "square.and.arrow.up") {}
                    // WIRED. This item was inert — a UGC feed with a Report button that did
                    // nothing is worse than one with no button, because it tells a reader their
                    // complaint was filed when no row was ever written. It now opens the same
                    // `ReportSheet` clips and profiles use, against `community_post` (053).
                    Button("Report", systemImage: "exclamationmark.triangle",
                           role: .destructive) {
                        Haptics.tap()
                        onReport()
                    }
                    // Last, after a divider, and only where it can succeed. The confirmation
                    // is the parent's alert — a destructive menu item that acts on the tap is
                    // one slip away from removing a post nobody meant to.
                    if let onDelete {
                        Divider()
                        Button("Delete post", systemImage: "trash", role: .destructive) {
                            Haptics.tap()
                            onDelete()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Post options")
            }

            Text(post.text)
                .font(VoiidFont.rounded(14.5))
                .foregroundColor(VoiidColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // The gradient is the SAME stand-in the reference used, now shown only for posts
            // that actually carry media. The block is drawn at the same 172pt whether or not
            // the image itself has been loaded, so the card never reflows underneath the reader.
            //
            // `media_url` is PLAINTEXT and holds EITHER a fetchable URL or an opaque R2 object
            // key — the column is named for a URL and 047 describes it as one, but the composer
            // now writes the key that `POST /media/presign-upload` returns, because that is the
            // only thing the upload path produces. `ResolvedThumbnail` handles both: a URL goes
            // straight through, a key is presigned on demand and cached by
            // `MediaKeyResolver`. THE LAYOUT IS UNCHANGED — same 172pt frame, same corner
            // radius, same gradient behind it.
            if let media = post.media_url, !media.isEmpty {
                RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AvatarPalette.color(for: post.id),
                                AvatarPalette.color(for: post.displayName).opacity(0.6),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 172)
                    .overlay {
                        ResolvedThumbnail(source: media)
                            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                        style: .continuous))
                    }
            }

            HStack(spacing: VoiidSpacing.lg) {
                // Filled when liked, and the count is the SERVER's — the join table is what
                // answers "did I like this", which is the whole reason 047 keeps one alongside
                // the counter.
                postAction(post.isLiked ? "heart.fill" : "heart", "\(post.likes)",
                           tint: post.isLiked ? VoiidColor.accent : nil,
                           action: onLike)
                // Comments have a COUNT but no thread: community_posts carries comment_count
                // and 047 defines no comments table, so there is nowhere for a tap to go. The
                // number is real; the button stays inert rather than opening an empty screen.
                postAction("bubble.left", "\(post.comments)")
                postAction("square.and.arrow.up", "Share")
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1)
        )
    }

    private func postAction(_ icon: String, _ label: String,
                            tint: Color? = nil,
                            action: (() -> Void)? = nil) -> some View {
        Button {
            Haptics.tap()
            action?()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: .medium))
                Text(label)
                    .font(VoiidFont.rounded(12.5))
            }
            .foregroundColor(tint ?? VoiidColor.textSecondary)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

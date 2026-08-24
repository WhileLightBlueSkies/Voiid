//
//  CommunityHomeTab.swift
//  Voiid
//
//  The Home tab inside a community — the admin dashboard, the pinned announcement and the
//  post feed. Ported from the reference's CommunityHomeScreen feed section.
//
//  ── STILL ON PLACEHOLDER DATA ───────────────────────────────────────────────────
//  Every number, task, announcement and post on this screen comes from
//  CommunityHomeModels.swift's `samples` and is the same for every community. There is no
//  posts table, no announcements table and no stats endpoint behind it yet. The layout is
//  real; the content is not.
//
//  The hero, identity, actions and tab bar live in CommunityDetailView — this file is only
//  what sits below the divider when Home is the selected tab.
//

import SwiftUI

struct CommunityHomeTab: View {
    /// Drives the admin dashboard. A member never renders it — the block is gated on the role
    /// rather than hidden behind a flag, so there is no build in which a member sees the queue.
    let isAdmin: Bool

    var body: some View {
        VStack(spacing: VoiidSpacing.md) {
            // Admins get the numbers and the queue first. A member scrolling Home wants the
            // feed; an admin opening Home wants to know what needs them.
            if isAdmin { adminDashboard }

            announcement

            ForEach(CommunityPost.samples) { post in
                CommunityPostCard(post: post)
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

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(AdminStat.samples) { stat in
                    statCard(stat)
                }
            }

            if !AdminTask.samples.isEmpty {
                HStack {
                    Text("Needs you")
                        .font(VoiidFont.rounded(15, .bold))
                        .foregroundColor(VoiidColor.textPrimary)

                    Text("\(AdminTask.samples.count)")
                        .font(VoiidFont.rounded(10.5, .bold))
                        .foregroundColor(VoiidColor.textOnAccent)
                        .frame(minWidth: 19, minHeight: 19)
                        .background(Circle().fill(VoiidColor.accent))

                    Spacer(minLength: 0)
                }
                .padding(.top, VoiidSpacing.sm)

                VStack(spacing: 8) {
                    ForEach(AdminTask.samples) { task in
                        taskRow(task)
                    }
                }
            }
        }
        .padding(.bottom, VoiidSpacing.sm)
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

            HStack(spacing: 3) {
                // Direction AND colour. Hue alone would fail for a colour-blind admin.
                Image(systemName: stat.isPositive ? "arrow.up.right" : "exclamationmark.circle")
                    .font(.system(size: 9, weight: .bold))
                Text(stat.delta)
                    .font(VoiidFont.rounded(10.5))
            }
            .foregroundColor(stat.isPositive ? VoiidColor.success : VoiidColor.warning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiidSpacing.sm + 2)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }

    private func taskRow(_ task: AdminTask) -> some View {
        HStack(spacing: VoiidSpacing.sm + 2) {
            Image(systemName: task.kind.icon)
                .font(.system(size: 13))
                .foregroundColor(task.kind == .report ? VoiidColor.warning
                                                      : VoiidColor.accentInk)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(task.kind == .report ? VoiidColor.warning.opacity(0.14)
                                               : VoiidColor.accentTint))

            VStack(alignment: .leading, spacing: 1) {
                Text(task.subject)
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                Text(task.detail)
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(task.age)
                .font(VoiidFont.rounded(10.5))
                .foregroundColor(VoiidColor.textSecondary)

            // Both answers on the row. A queue where acting means opening each item is a queue
            // that does not get cleared.
            HStack(spacing: 6) {
                Button {
                    Haptics.success()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(VoiidColor.textOnAccent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(VoiidColor.accent))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Approve")

                Button {
                    Haptics.tap()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(VoiidColor.surfaceRaised))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, VoiidSpacing.sm + 2)
        .frame(height: 58)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.kind.rawValue): \(task.subject), \(task.detail)")
    }

    // MARK: Announcement

    private var announcement: some View {
        let pinned = CommunityAnnouncement.sample

        return Button {
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

                    Text(pinned.title)
                        .font(VoiidFont.rounded(14.5, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .multilineTextAlignment(.leading)

                    Text(pinned.body)
                        .font(VoiidFont.rounded(13))
                        .foregroundColor(VoiidColor.textSecondary)
                        .multilineTextAlignment(.leading)

                    Text("By \(pinned.author) · \(pinned.age)")
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

// MARK: - A post

private struct CommunityPostCard: View {
    let post: CommunityPost

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(spacing: 9) {
                CommunityAvatar(name: post.author, size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(post.author)
                        .font(VoiidFont.rounded(14, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    Text(post.age)
                        .font(VoiidFont.rounded(11.5))
                        .foregroundColor(VoiidColor.textSecondary)
                }

                Spacer(minLength: 0)

                Menu {
                    Button("Save post", systemImage: "bookmark") {}
                    Button("Share", systemImage: "square.and.arrow.up") {}
                    Button("Report", systemImage: "exclamationmark.triangle",
                           role: .destructive) {}
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

            if post.hasMedia {
                RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                AvatarPalette.color(for: post.id),
                                AvatarPalette.color(for: post.author).opacity(0.6),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 172)
            }

            HStack(spacing: VoiidSpacing.lg) {
                postAction("heart", "128")
                postAction("bubble.left", "24")
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

    private func postAction(_ icon: String, _ label: String) -> some View {
        Button {
            Haptics.tap()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: .medium))
                Text(label)
                    .font(VoiidFont.rounded(12.5))
            }
            .foregroundColor(VoiidColor.textSecondary)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

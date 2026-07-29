//
//  StoryViewersSheet.swift
//  Voiid
//
//  The author's viewer list for one of their own stories, read from local `story_views`
//  (built from decrypted receipts). When view receipts are OFF (the default), this shows
//  the reciprocity copy instead of names and does NOT read the viewer list — the opt-out is
//  reciprocal (§4.4).
//

import SwiftUI

struct StoryViewersSheet: View {
    let story: Story
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = StorySettings.shared

    private var viewers: [(userId: String, viewedAt: Date)] {
        settings.sendViewReceipts ? StoryStore.viewers(storyId: story.id) : []
    }

    var body: some View {
        NavigationStack {
            Group {
                if !settings.sendViewReceipts {
                    reciprocityCopy
                } else if viewers.isEmpty {
                    empty
                } else {
                    List {
                        ForEach(viewers, id: \.userId) { v in
                            HStack(spacing: VoiidSpacing.md) {
                                ProfileAvatarButton(photoURL: UserDirectory.shared.photoURL(v.userId),
                                                    name: UserDirectory.shared.displayName(v.userId), size: 40)
                                Text(UserDirectory.shared.displayName(v.userId)).foregroundColor(VoiidColor.textPrimary)
                                Spacer()
                                Text(relative(v.viewedAt)).font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
                            }
                            .listRowBackground(VoiidColor.surfaceCard)
                        }
                    }
                    .voiidSettingsList()
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle(settings.sendViewReceipts ? "\(viewers.count) views" : "Views")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private var reciprocityCopy: some View {
        VStack(spacing: VoiidSpacing.md) {
            Image(systemName: "eye.slash").font(.system(size: 40)).foregroundColor(VoiidColor.textSecondary)
            Text("If you turn this off, people won't know when you've viewed their moment — and you won't see who viewed yours.")
                .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
            Text("Turn on view receipts in Settings → Privacy.")
                .font(VoiidFont.caption).foregroundColor(VoiidColor.placeholder)
        }
        .padding(VoiidSpacing.xl)
    }

    private var empty: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "eye").font(.system(size: 40)).foregroundColor(VoiidColor.textSecondary)
            Text("No views yet").font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
        }
        .padding(VoiidSpacing.xl)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

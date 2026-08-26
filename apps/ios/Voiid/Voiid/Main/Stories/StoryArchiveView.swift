//
//  StoryArchiveView.swift
//  Voiid
//
//  The author's kept moments, after the 24 hours are up.
//
//  This screen is AUTHOR-ONLY by construction, not by a check bolted on top:
//  `StoryStore.archived()` filters `is_mine = 1`, and `setArchived` refuses any row
//  that is not the author's. A moment someone shares with you always expires — the
//  promise a moment makes is "these people, 24 hours", and an archive that kept other
//  people's content would quietly retract it on their behalf.
//
//  Nothing here is uploaded. An archived moment is the plaintext file `postStory`
//  already cached at post time, on this device only, so the archive costs no new bytes
//  and the server has no idea it exists.
//

import SwiftUI

struct StoryArchiveView: View {

    @State private var items: [Story] = []
    @State private var openContext: StoryContext?
    @State private var pendingDelete: Story?

    /// Same two-column mesh as the Moments grid so the archive reads as the same shelf,
    /// just older — see StoriesHomeView's note on why two and not three.
    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            if items.isEmpty {
                empty
            } else {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(items) { story in
                        // One archived moment = one single-story context. They are kept
                        // individually, so grouping them by author (the tray's model)
                        // would make a whole day open as one reel the user can't leave
                        // partway through.
                        let ctx = StoryContext(authorId: story.authorId, stories: [story])
                        StoryMomentCard(context: ctx) { openContext = ctx }
                            .contextMenu {
                                Button(role: .destructive) { pendingDelete = story } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.sm)
                .padding(.bottom, VoiidSpacing.xl)
            }
        }
        .scrollIndicators(.hidden)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .fullScreenCover(item: $openContext, onDismiss: reload) { ctx in
            StoryViewerView(contexts: [ctx], startAuthorId: ctx.authorId)
        }
        // A confirmation, not a silent swipe: this is the only copy left anywhere, so
        // the delete is genuinely irreversible — the viewers' copies expired long ago.
        .confirmationDialog("Delete this moment?",
                            isPresented: .init(get: { pendingDelete != nil },
                                               set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let s = pendingDelete { StoryStore.setArchived(s.id, false); reload() }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This is the only copy left. It can’t be undone.")
        }
    }

    private var empty: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "archivebox")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(VoiidColor.placeholder)
            Text("No kept moments yet")
                .font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
            // Names the switch that fills this screen, so an empty state is a next step
            // rather than a dead end.
            Text("Moments you keep stay here after they expire — only on this device.")
                .font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, VoiidSpacing.xl)
        .padding(.top, 96)
    }

    private func reload() { items = StoryStore.archived() }
}

//
//  ClipCommentsView.swift
//  Voiid
//
//  Clips comments sheet (Figma Screen-10.5).
//

import SwiftUI

struct ClipCommentsView: View {
    @EnvironmentObject var clips: ClipsStore
    @State private var draft = ""
    var body: some View {
        VStack(spacing: 0) {
            Text("Comments").font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary).padding()
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    ForEach(clips.comments) { c in
                        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                            VoiidAvatar(size: 30, imageName: c.authorPhoto)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.authorName).font(VoiidFont.subhead).foregroundColor(VoiidColor.textPrimary)
                                Text(c.text).font(VoiidFont.footnote).foregroundColor(VoiidColor.textSecondary)
                            }
                        }
                    }
                }.padding()
            }
            Divider()
            HStack {
                TextField("Add a comment…", text: $draft)
                    .font(VoiidFont.body).padding(.horizontal, VoiidSpacing.md).frame(height: 44)
                    .background(VoiidColor.fieldFill).clipShape(Capsule())
                Button {
                    let t = draft.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
                    Haptics.tap(); clips.addComment(t); draft = ""
                } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundColor(VoiidColor.primary) }
            }.padding()
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }
}

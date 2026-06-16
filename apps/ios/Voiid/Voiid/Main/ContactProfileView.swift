//
//  ContactProfileView.swift
//  Voiid
//
//  1:1 contact profile (WhatsApp-style): header (photo/name/phone) + quick
//  actions, about/status, shared media, mute/search/wallpaper, block/report.
//  Native back button. Dummy data.
//

import SwiftUI

struct ContactProfileView: View {
    let conversation: VConversation
    @Environment(\.dismiss) private var dismiss
    @State private var muted = false

    var body: some View {
        ScrollView {
            VStack(spacing: VoiidSpacing.lg) {
                headerCard
                aboutCard
                sharedMediaCard
                settingsCard
                dangerCard
            }
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.vertical, VoiidSpacing.lg)
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(VoiidColor.primary)
    }

    // Header: photo, name, phone, quick actions (message / call / video)
    private var headerCard: some View {
        VStack(spacing: VoiidSpacing.sm) {
            VoiidAvatar(size: 110, imageName: conversation.photoName).clipShape(Circle())
            Text(conversation.title).font(VoiidFont.rounded(22, .bold)).foregroundColor(VoiidColor.textPrimary)
            Text("+91 91234 56789").font(VoiidFont.rounded(14, .regular)).foregroundColor(VoiidColor.textSecondary)

            HStack(spacing: VoiidSpacing.md) {
                quickAction("message.fill", "Message") { dismiss() }
                quickAction("phone.fill", "Call") {}
                quickAction("video.fill", "Video") {}
            }
            .padding(.top, VoiidSpacing.sm)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoiidSpacing.md)
    }

    private func quickAction(_ icon: String, _ label: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); tap() }) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 20)).foregroundColor(VoiidColor.primary)
                    .frame(width: 56, height: 48)
                    .background(VoiidColor.accent.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                Text(label).font(VoiidFont.rounded(11, .medium)).foregroundColor(VoiidColor.textSecondary)
            }
        }
        .buttonStyle(SoftPressStyle())
    }

    private var aboutCard: some View {
        card {
            Text("About").font(VoiidFont.rounded(13, .medium)).foregroundColor(VoiidColor.textSecondary)
            Text("Hey there! I am using Voiid.")
                .font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
        }
    }

    private var sharedMediaCard: some View {
        card {
            HStack {
                Text("Media, links & docs").font(VoiidFont.rounded(15, .semibold)).foregroundColor(VoiidColor.textPrimary)
                Spacer()
                Button("See all") {}.font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.primary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VoiidSpacing.sm) {
                    ForEach(DummyData.sharedMedia.prefix(6)) { _ in
                        RoundedRectangle(cornerRadius: VoiidRadius.md)
                            .fill(VoiidColor.accent.opacity(0.35))
                            .frame(width: 72, height: 72)
                            .overlay(Image(systemName: "photo").foregroundColor(VoiidColor.primary))
                    }
                }
            }
        }
    }

    private var settingsCard: some View {
        card {
            Toggle(isOn: $muted) {
                Label("Mute notifications", systemImage: "bell.slash")
                    .font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
            }.tint(VoiidColor.primary)
            Divider().background(VoiidColor.divider.opacity(0.4))
            row("magnifyingglass", "Search in chat") {}
            Divider().background(VoiidColor.divider.opacity(0.4))
            row("photo.on.rectangle", "Wallpaper") {}
        }
    }

    private var dangerCard: some View {
        card {
            actionRow("hand.raised.fill", "Block \(conversation.title)") {}
            Divider().background(VoiidColor.divider.opacity(0.4))
            actionRow("exclamationmark.bubble.fill", "Report \(conversation.title)") {}
        }
    }

    // MARK: helpers
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) { content() }
            .padding(VoiidSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }

    private func row(_ icon: String, _ text: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: VoiidSpacing.md) {
                Image(systemName: icon).font(.system(size: 17)).foregroundColor(VoiidColor.textPrimary).frame(width: 24)
                Text(text).font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
                Spacer()
            }.padding(.vertical, 4)
        }.buttonStyle(.plain)
    }

    private func actionRow(_ icon: String, _ text: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: { Haptics.rigid(); tap() }) {
            HStack(spacing: VoiidSpacing.md) {
                Image(systemName: icon).font(.system(size: 17)).foregroundColor(VoiidColor.error).frame(width: 24)
                Text(text).font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.error)
                Spacer()
            }.padding(.vertical, 4)
        }.buttonStyle(.plain)
    }
}

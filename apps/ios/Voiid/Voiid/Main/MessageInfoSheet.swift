//
//  MessageInfoSheet.swift
//  Voiid
//
//  Message Info (WhatsApp-style): the message + Delivered / Read times.
//  Works for 1:1 and group. Dummy timestamps from the message lifecycle.
//

import SwiftUI

struct MessageInfoSheet: View {
    let message: VMessage
    let isGroup: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: VoiidSpacing.lg) {
                // Message preview bubble
                HStack {
                    Spacer(minLength: 48)
                    Text(message.kind == .text ? message.text : "Attachment")
                        .font(VoiidFont.rounded(15, .regular)).foregroundColor(VoiidColor.textPrimary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(VoiidColor.bubbleReceived)
                        .clipShape(BubbleShape(isMine: true))
                }

                VStack(spacing: 0) {
                    infoRow(icon: "checkmark.circle", color: VoiidColor.textSecondary,
                            label: "Delivered", time: message.deliveredAt)
                    Divider().background(VoiidColor.divider.opacity(0.4))
                    infoRow(icon: "checkmark.circle.fill", color: VoiidColor.primary,
                            label: "Read", time: message.readAt)
                }
                .background(VoiidColor.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))

                if isGroup {
                    Text("In groups, delivered/read reflects all members.")
                        .font(VoiidFont.rounded(12, .regular)).foregroundColor(VoiidColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
            }
            .padding(VoiidSpacing.lg)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Message info").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Haptics.tap(); dismiss() } label: {
                        Text("Done").fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VoiidColor.primary)
                    .controlSize(.small)
                }
            }
        }
    }

    private func infoRow(icon: String, color: Color, label: String, time: Date?) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            Image(systemName: icon).font(.system(size: 18)).foregroundColor(color).frame(width: 24)
            Text(label).font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
            Spacer()
            Text(time.map(timeString) ?? "—")
                .font(VoiidFont.rounded(14, .regular)).foregroundColor(VoiidColor.textSecondary)
        }
        .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.md)
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
    }
}

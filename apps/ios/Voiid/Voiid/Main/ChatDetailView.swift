//
//  ChatDetailView.swift
//  Voiid
//
//  1:1 / group chat. Full experience on dummy data:
//   • bubbles: sent = light pink (#FCF4F8), received = white (#FFFFFF)
//   • refined receipts: tap a bubble for its time; Sent/Delivered/Read only under last sent msg
//   • date separators (Today / Yesterday / date) + typing indicator
//   • voice notes (record + send + playback), images (pick + send + fullscreen)
//   • no bottom tab bar here (hidden via session.hideTabBar)
//

import SwiftUI
import PhotosUI

struct ChatDetailView: View {
    let conversation: VConversation
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var fullscreenImage: UIImage?
    @State private var showInfo = false       // group info / contact profile

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            inputBar
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // Hide the bottom tab bar while a chat is open; restore on leave.
        .onAppear { session.hideTabBar = true }
        .onDisappear { session.hideTabBar = false }
        .navigationDestination(isPresented: $showInfo) {
            if conversation.type == .group {
                GroupInfoView(conversation: conversation)
            } else {
                ContactProfileView(conversation: conversation)
            }
        }
        .fullScreenCover(item: Binding(
            get: { fullscreenImage.map { ImageWrapper(image: $0) } },
            set: { fullscreenImage = $0?.image })
        ) { wrapper in
            ImageViewer(image: wrapper.image) { fullscreenImage = nil }
        }
    }

    // MARK: header — back, avatar, name/presence, camera · phone · ⋮

    private var header: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Button { Haptics.tap(); dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
            }
            Button {
                Haptics.tap(); showInfo = true
            } label: {
                HStack(spacing: VoiidSpacing.sm) {
                    VoiidAvatar(size: 36, imageName: conversation.photoName)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(conversation.title)
                            .font(VoiidFont.rounded(17, .semibold)).foregroundColor(VoiidColor.textPrimary)
                        Text(presenceText)
                            .font(VoiidFont.rounded(11, .regular))
                            .foregroundColor(chat.typingConversations.contains(conversation.id) ? VoiidColor.primary : VoiidColor.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            HStack(spacing: VoiidSpacing.lg) {
                Image(systemName: "camera").font(.system(size: 19)).foregroundColor(VoiidColor.textPrimary)
                Image(systemName: "phone.fill").font(.system(size: 18)).foregroundColor(VoiidColor.textPrimary)
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundColor(VoiidColor.textPrimary)
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
        .background(VoiidColor.background)
    }

    private var presenceText: String {
        if chat.typingConversations.contains(conversation.id) { return "typing…" }
        if conversation.type == .group { return "\(conversation.memberCount) members" }
        return conversation.isOnline ? "Online" : "last seen recently"
    }

    // MARK: message list with date separators + auto-scroll

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: VoiidSpacing.sm) {
                    ForEach(groupedByDay, id: \.0) { day, msgs in
                        DateSeparator(text: day)
                        ForEach(msgs) { msg in
                            MessageBubble(message: msg,
                                          isGroup: conversation.type == .group,
                                          isLastMine: msg.id == lastMineID) { img in
                                fullscreenImage = img
                            }
                            .id(msg.id)
                        }
                    }
                    if chat.typingConversations.contains(conversation.id) {
                        TypingBubble().id("typing")
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, VoiidSpacing.md)
            }
            .onChange(of: chat.messages(for: conversation.id).count) { _, _ in
                withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
            }
            .onChange(of: chat.typingConversations) { _, _ in
                withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(lastID, anchor: .bottom) }
        }
    }

    private var lastID: String { chat.messages(for: conversation.id).last?.id ?? "" }
    private var lastMineID: String { chat.messages(for: conversation.id).last(where: { $0.isMine })?.id ?? "" }

    /// Group messages by calendar day for separators.
    private var groupedByDay: [(String, [VMessage])] {
        let msgs = chat.messages(for: conversation.id)
        let groups = Dictionary(grouping: msgs) { Calendar.current.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted().map { (VoiidDate.separator($0), groups[$0]!.sorted { $0.createdAt < $1.createdAt }) }
    }

    // MARK: input bar (text + attach image + voice note)

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty }

    // Input bar — ⊕ · pink pill field · send/voice (matches design)
    private var inputBar: some View {
        HStack(spacing: VoiidSpacing.sm) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundColor(VoiidColor.textPrimary)
            }
            .onChange(of: photoItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self) {
                        chat.send("📷 Photo", kind: .image, to: conversation.id)
                        photoItem = nil; _ = data
                    }
                }
            }

            TextField("", text: $draft, axis: .vertical)
                .font(VoiidFont.rounded(16, .regular))
                .foregroundColor(VoiidColor.textPrimary)
                .lineLimit(1...5)
                .padding(.horizontal, VoiidSpacing.md)
                .frame(minHeight: 46)

            if hasText {
                Button {
                    Haptics.tap()
                    chat.send(draft.trimmingCharacters(in: .whitespaces), to: conversation.id)
                    draft = ""
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 20)).foregroundColor(VoiidColor.primary)
                        .padding(.trailing, VoiidSpacing.sm)
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                VoiceRecordButton { duration in
                    chat.send("🎤 Voice message · \(Int(duration))s", kind: .voice, to: conversation.id)
                }
                .padding(.trailing, VoiidSpacing.sm)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, VoiidSpacing.xs)
        .padding(.leading, VoiidSpacing.sm)
        .background(VoiidColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.pill).stroke(VoiidColor.fieldBorder, lineWidth: 1))
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .padding(.bottom, VoiidSpacing.sm)
        .background(VoiidColor.background)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasText)
    }
}

// MARK: - Message bubble with ticks + timestamp

struct MessageBubble: View {
    let message: VMessage
    let isGroup: Bool
    var isLastMine: Bool = false      // (kept for call-site compatibility)
    var onTapImage: (UIImage) -> Void

    var body: some View {
        // System message — centered pill (e.g. "You added Priyanshu").
        if message.kind == .system {
            Text(message.text)
                .font(VoiidFont.rounded(11, .medium))
                .foregroundColor(VoiidColor.textSecondary)
                .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 5)
                .background(VoiidColor.surfaceCard.opacity(0.7))
                .clipShape(Capsule())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        HStack {
            if message.isMine { Spacer(minLength: 56) }
            VStack(alignment: .leading, spacing: 1) {
                // Sender name (group, incoming only) — colored per sender
                if isGroup && !message.isMine && !message.senderName.isEmpty {
                    Text(message.senderName)
                        .font(VoiidFont.rounded(12, .semibold))
                        .foregroundColor(message.senderColor)
                }
                // Text + inline time/tick on the same trailing edge (WhatsApp-tight)
                if message.kind == .text {
                    textWithMeta
                } else {
                    content
                    metaRow.padding(.top, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(message.isMine ? VoiidColor.bubbleReceived : VoiidColor.surfaceCard)
            .clipShape(BubbleShape(isMine: message.isMine))
            if !message.isMine { Spacer(minLength: 56) }
        }
        .padding(.vertical, 1)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9, anchor: message.isMine ? .bottomTrailing : .bottomLeading).combined(with: .opacity),
            removal: .opacity))
    }

    // Text bubble: message + (time · tick) flowing at the end, compact like WhatsApp.
    private var textWithMeta: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Text(message.text)
                .font(VoiidFont.rounded(15, .regular))
                .foregroundColor(VoiidColor.textPrimary)
            metaRow
        }
    }

    private var metaRow: some View {
        HStack(spacing: 3) {
            Text(VoiidDate.bubbleTime(message.createdAt))
                .font(VoiidFont.rounded(10, .regular))
                .foregroundColor(VoiidColor.textSecondary.opacity(0.8))
            if message.isMine { tick }
        }
    }

    @ViewBuilder private var tick: some View {
        switch message.status {
        case .sending: Image(systemName: "clock").font(.system(size: 9)).foregroundColor(VoiidColor.textSecondary)
        case .sent:    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundColor(VoiidColor.textSecondary)
        case .delivered: doubleTick(VoiidColor.textSecondary)
        case .read:    doubleTick(VoiidColor.primary)
        case .failed:  Image(systemName: "exclamationmark.circle").font(.system(size: 9)).foregroundColor(VoiidColor.error)
        }
    }
    private func doubleTick(_ c: Color) -> some View {
        ZStack {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).offset(x: -2.5)
            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).offset(x: 1.5)
        }.foregroundColor(c)
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .image:
            RoundedRectangle(cornerRadius: VoiidRadius.md)
                .fill(VoiidColor.accent.opacity(0.4))
                .frame(width: 200, height: 200)
                .overlay(Image(systemName: "photo").font(.system(size: 40)).foregroundColor(VoiidColor.primary))
        case .voice:
            VoiceNotePlayer(label: message.text)
        default:
            Text(message.text).font(VoiidFont.rounded(15, .regular)).foregroundColor(VoiidColor.textPrimary)
        }
    }
}

// MARK: - Date separator pill

struct DateSeparator: View {
    let text: String
    var body: some View {
        Text(text)
            .font(VoiidFont.rounded(11, .medium))
            .foregroundColor(VoiidColor.textSecondary)
            .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 4)
            .background(VoiidColor.surfaceCard.opacity(0.7))
            .clipShape(Capsule())
            .padding(.vertical, VoiidSpacing.sm)
    }
}

// MARK: - Typing indicator bubble

struct TypingBubble: View {
    @State private var phase = 0.0
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(VoiidColor.textSecondary)
                        .frame(width: 7, height: 7)
                        .opacity(phase == Double(i) ? 1 : 0.3)
                }
            }
            .padding(.horizontal, VoiidSpacing.md).padding(.vertical, 12)
            .background(VoiidColor.bubbleReceived)
            .clipShape(BubbleShape(isMine: false))
            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) { phase = 2 }
        }
    }
}

// MARK: - Bubble shape (tail on the correct side)

struct BubbleShape: Shape {
    let isMine: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 16
        let corners: UIRectCorner = isMine
            ? [.topLeft, .topRight, .bottomLeft]
            : [.topLeft, .topRight, .bottomRight]
        return Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                 cornerRadii: CGSize(width: r, height: r)).cgPath)
    }
}

// MARK: - Image viewer

struct ImageWrapper: Identifiable { let id = UUID(); let image: UIImage }

struct ImageViewer: View {
    let image: UIImage
    let onClose: () -> Void
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image).resizable().scaledToFit()
            VStack { HStack { Spacer()
                Button { onClose() } label: { Image(systemName: "xmark").font(.title2).foregroundColor(.white).padding() }
            }; Spacer() }
        }
    }
}

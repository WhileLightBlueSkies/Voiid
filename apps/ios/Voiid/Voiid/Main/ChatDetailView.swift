//
//  ChatDetailView.swift
//  Voiid
//
//  1:1 / group chat (Figma Screen-11/12). Full experience on dummy data:
//   • message bubbles (sent = #C8C8C8, received = #FCF4F8)
//   • status ticks (sending → sent → delivered → read)
//   • per-bubble timestamps + date separators (Today / Yesterday / date)
//   • typing indicator
//   • voice notes (record + send + playback)  — see VoiceNote.swift
//   • images (pick + send + fullscreen view)
//

import SwiftUI
import PhotosUI

struct ChatDetailView: View {
    let conversation: VConversation
    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var fullscreenImage: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            inputBar
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: Binding(
            get: { fullscreenImage.map { ImageWrapper(image: $0) } },
            set: { fullscreenImage = $0?.image })
        ) { wrapper in
            ImageViewer(image: wrapper.image) { fullscreenImage = nil }
        }
    }

    // MARK: header (Figma: back, avatar, name, presence, camera/call/menu)

    private var header: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Button { Haptics.tap(); dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                    .foregroundColor(VoiidColor.primary)
            }
            VoiidAvatar(size: 35, imageName: conversation.photoName)
            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.title).font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
                Text(presenceText).font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
            }
            Spacer()
            Image(systemName: "camera").foregroundColor(VoiidColor.primary)
            Image(systemName: "phone").foregroundColor(VoiidColor.primary).padding(.horizontal, VoiidSpacing.sm)
            Image(systemName: "ellipsis").foregroundColor(VoiidColor.primary)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .bottom)
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
                            MessageBubble(message: msg, isGroup: conversation.type == .group) { img in
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

    /// Group messages by calendar day for separators.
    private var groupedByDay: [(String, [VMessage])] {
        let msgs = chat.messages(for: conversation.id)
        let groups = Dictionary(grouping: msgs) { Calendar.current.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted().map { (VoiidDate.separator($0), groups[$0]!.sorted { $0.createdAt < $1.createdAt }) }
    }

    // MARK: input bar (text + attach image + voice note)

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: VoiidSpacing.sm) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundColor(VoiidColor.primary)
                }
                .onChange(of: photoItem) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self) {
                            chat.send("📷 Photo", kind: .image, to: conversation.id)
                            photoItem = nil
                            _ = data
                        }
                    }
                }

                HStack {
                    TextField("Message", text: $draft, axis: .vertical)
                        .font(VoiidFont.body).lineLimit(1...4)
                    if draft.isEmpty {
                        Image(systemName: "camera.fill").foregroundColor(VoiidColor.textSecondary)
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
                .frame(minHeight: 44)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.pill).stroke(VoiidColor.fieldBorder))

                if draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    VoiceRecordButton { duration in
                        chat.send("🎤 Voice message · \(Int(duration))s", kind: .voice, to: conversation.id)
                    }
                } else {
                    Button {
                        Haptics.tap()
                        chat.send(draft.trimmingCharacters(in: .whitespaces), to: conversation.id)
                        draft = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundColor(VoiidColor.primary)
                    }
                    .transition(.scale)
                }
            }
            .padding(.horizontal, VoiidSpacing.sm)
            .padding(.vertical, VoiidSpacing.sm)
            .padding(.bottom, 80) // clears the custom tab bar
            .background(.ultraThinMaterial)
            .animation(.spring(response: 0.3), value: draft.isEmpty)
        }
    }
}

// MARK: - Message bubble with ticks + timestamp

struct MessageBubble: View {
    let message: VMessage
    let isGroup: Bool
    var onTapImage: (UIImage) -> Void

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 40) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                content
                HStack(spacing: 4) {
                    Text(VoiidDate.bubbleTime(message.createdAt))
                        .font(VoiidFont.rounded(10, .regular))
                        .foregroundColor(VoiidColor.textSecondary)
                    if message.isMine { StatusTicks(status: message.status) }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.sm)
            .background(message.isMine ? VoiidColor.bubbleSent : VoiidColor.bubbleReceived)
            .clipShape(BubbleShape(isMine: message.isMine))
            if !message.isMine { Spacer(minLength: 40) }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.85, anchor: message.isMine ? .bottomTrailing : .bottomLeading).combined(with: .opacity),
            removal: .opacity))
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .image:
            RoundedRectangle(cornerRadius: VoiidRadius.md)
                .fill(VoiidColor.accent.opacity(0.4))
                .frame(width: 180, height: 180)
                .overlay(Image(systemName: "photo").font(.system(size: 40)).foregroundColor(VoiidColor.primary))
        case .voice:
            VoiceNotePlayer(label: message.text)
        default:
            Text(message.text).font(VoiidFont.body).foregroundColor(VoiidColor.textPrimary)
        }
    }
}

// MARK: - Status ticks (sending → sent → delivered → read)

struct StatusTicks: View {
    let status: MessageStatus
    var body: some View {
        switch status {
        case .sending:
            Image(systemName: "clock").font(.system(size: 10)).foregroundColor(VoiidColor.textSecondary)
        case .sent:
            Image(systemName: "checkmark").font(.system(size: 10)).foregroundColor(VoiidColor.textSecondary)
        case .delivered:
            doubleTick(VoiidColor.textSecondary)
        case .read:
            doubleTick(VoiidColor.success)
        case .failed:
            Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundColor(VoiidColor.error)
        }
    }
    private func doubleTick(_ color: Color) -> some View {
        ZStack {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).offset(x: -3)
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).offset(x: 1)
        }.foregroundColor(color)
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

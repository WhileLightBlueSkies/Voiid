//
//  AIHubView.swift
//  Voiid AI — the tab's landing screen.
//
//  Ported from the reference app's `AI/AIHubScreen.swift`. Layout, spacing, hierarchy and
//  copy are the reference's; the Recent list is backed by real stored conversations rather
//  than sample rows.
//
//  ── A HUB EXISTS TO SKIP THE BLANK PAGE ─────────────────────────────────────────
//  The hardest part of an assistant is the empty text field: people open it, cannot think of
//  what to ask, and leave. Every card here opens a conversation with its prompt ALREADY SENT,
//  so the first thing you see is a reply rather than a cursor.
//
//  The composer at the bottom is for people who already know what they want. It is deliberately
//  the quietest thing on the screen — the cards are the answer to "what can this do?", and the
//  field is the answer to "I already know".
//

import SwiftUI

struct AIHubView: View {

    @EnvironmentObject var session: AppSession

    /// Set when a conversation should open. Carries what to open it with.
    @State private var opening: AIOpening?
    @State private var draft = ""
    @State private var threads: [AIThread] = []
    @State private var availability: AIAvailability = .osTooOld
    @State private var confirmingClearAll = false

    private let tools = AITool.all

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                        greeting
                        featured
                        moreTools
                        if !threads.isEmpty { recent }
                    }
                    .padding(.top, VoiidSpacing.sm)
                }
                .scrollIndicators(.hidden)
                .softTopEdgeEffect()
                .contentMargins(.bottom, max(session.bottomInset, 96) + 64,
                                for: .scrollContent)

                composer
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $opening) { opening in
                AIChatView(opening: opening, onFinish: reload)
            }
        }
        .onAppear {
            // Availability can change between launches — Apple Intelligence gets switched
            // on, the model finishes downloading — so it is read on every appearance rather
            // than cached for the life of the process.
            availability = .current
            reload()
        }
    }

    private func reload() {
        threads = AIStore.threads()
    }

    // MARK: Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(VoiidColor.accentInk)

                Text("Voiid AI")
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(VoiidColor.accentInk)
                    .tracking(0.4)

                Spacer(minLength: 0)

                if !threads.isEmpty {
                    Menu {
                        Button("Clear all conversations", systemImage: "trash",
                               role: .destructive) {
                            confirmingClearAll = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(VoiidColor.textSecondary)
                            .frame(width: 30, height: 30)
                    }
                    .accessibilityLabel("Voiid AI options")
                }
            }

            Text("What can I help with?")
                .font(VoiidFont.rounded(28, .bold))
                .foregroundColor(VoiidColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // The reference said "I can see your chats, Spaces and events". It cannot, and
            // neither can this: the model runs on-device with no access to the message
            // store. Promising otherwise on the first screen would be the one lie the whole
            // feature rests on, so the copy says what is actually true and sells the part
            // that is genuinely unusual — that nothing leaves the phone.
            Text("Ask me anything. I run on your device, so nothing you type is sent anywhere.")
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let notice = availability.notice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .padding(.top, 2)
                    Text(notice)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(VoiidFont.rounded(12))
                .foregroundColor(VoiidColor.textSecondary)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .confirmationDialog("Clear all conversations?",
                            isPresented: $confirmingClearAll, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) {
                Haptics.tap()
                AIStore.deleteAll()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every Voiid AI conversation from this device. It can't be undone.")
        }
    }

    // MARK: Featured

    /// The two things people actually open an assistant for, given a full-width card each.
    private var featured: some View {
        VStack(spacing: VoiidSpacing.sm + 2) {
            ForEach(tools.filter(\.isFeatured)) { tool in
                Button {
                    opening = AIOpening(prompt: tool.openingPrompt)
                } label: {
                    HStack(spacing: VoiidSpacing.md) {
                        Image(systemName: tool.icon)
                            .font(.system(size: 19))
                            .foregroundColor(VoiidColor.textOnAccent)
                            .frame(width: 46, height: 46)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(VoiidColor.accent))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.title)
                                .font(VoiidFont.rounded(16, .semibold))
                                .foregroundColor(VoiidColor.textPrimary)
                            Text(tool.subtitle)
                                .font(VoiidFont.rounded(13))
                                .foregroundColor(VoiidColor.textSecondary)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                    .padding(VoiidSpacing.md - 2)
                    .background(VoiidColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg,
                                                style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                        .stroke(VoiidColor.accent.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(SoftPressStyle(scale: 0.97))
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    // MARK: The rest

    private var moreTools: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm + 2) {
            Text("More")
                .font(VoiidFont.rounded(15, .bold))
                .foregroundColor(VoiidColor.textPrimary)
                .padding(.horizontal, VoiidSpacing.md)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(tools.filter { !$0.isFeatured }) { tool in
                    Button {
                        opening = AIOpening(prompt: tool.openingPrompt)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: tool.icon)
                                .font(.system(size: 16))
                                .foregroundColor(VoiidColor.accentInk)
                                .frame(width: 36, height: 36)
                                .background(RoundedRectangle(cornerRadius: 11,
                                                             style: .continuous)
                                    .fill(VoiidColor.accentTint))

                            Text(tool.title)
                                .font(VoiidFont.rounded(14, .semibold))
                                .foregroundColor(VoiidColor.textPrimary)

                            Text(tool.subtitle)
                                .font(VoiidFont.rounded(11.5))
                                .foregroundColor(VoiidColor.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(VoiidSpacing.sm + 4)
                        .background(VoiidColor.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                    style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                  style: .continuous)
                            .stroke(VoiidColor.divider, lineWidth: 1))
                    }
                    .buttonStyle(SoftPressStyle(scale: 0.97))
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
        }
    }

    // MARK: Recent

    /// Real stored conversations. The reference's "See all" is gone: it went nowhere there,
    /// and here the list already holds everything worth showing.
    private var recent: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm + 2) {
            Text("Recent")
                .font(VoiidFont.rounded(15, .bold))
                .foregroundColor(VoiidColor.textPrimary)
                .padding(.horizontal, VoiidSpacing.md)

            VStack(spacing: 0) {
                ForEach(Array(threads.enumerated()), id: \.element.id) { i, thread in
                    Button {
                        opening = AIOpening(threadID: thread.id)
                    } label: {
                        HStack(spacing: VoiidSpacing.sm + 2) {
                            Image(systemName: thread.icon)
                                .font(.system(size: 14))
                                .foregroundColor(VoiidColor.textSecondary)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(VoiidColor.surfaceRaised))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(thread.title)
                                    .font(VoiidFont.rounded(14, .semibold))
                                    .foregroundColor(VoiidColor.textPrimary)
                                    .lineLimit(1)
                                Text(thread.preview)
                                    .font(VoiidFont.rounded(12))
                                    .foregroundColor(VoiidColor.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Text(thread.age)
                                .font(VoiidFont.rounded(11))
                                .foregroundColor(VoiidColor.textSecondary)
                        }
                        .padding(.horizontal, VoiidSpacing.md - 2)
                        .frame(height: 58)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Haptics.tap()
                            AIStore.delete(threadID: thread.id)
                            reload()
                        }
                    }

                    if i < threads.count - 1 {
                        Divider().overlay(VoiidColor.divider)
                            .padding(.leading, VoiidSpacing.xl + 6)
                    }
                }
            }
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1))
            .padding(.horizontal, VoiidSpacing.md)
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundColor(VoiidColor.accentInk)

                TextField("Ask anything", text: $draft)
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
                    .submitLabel(.send)
                    .onSubmit(start)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .frame(height: 48)
            .background(VoiidColor.surfaceCard)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))

            Button(action: start) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(VoiidColor.accent))
            }
            .buttonStyle(SoftPressStyle(scale: 0.97))
            .disabled(trimmedDraft.isEmpty)
            .opacity(trimmedDraft.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.bottom, max(session.bottomInset, 96) + VoiidSpacing.sm)
        .padding(.top, VoiidSpacing.md)
        .background(
            LinearGradient(colors: [VoiidColor.background.opacity(0),
                                    VoiidColor.background.opacity(0.92),
                                    VoiidColor.background],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func start() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        Haptics.tap()
        draft = ""
        opening = AIOpening(prompt: text)
    }
}

/// What to open the chat with: either a prompt to send on arrival, or a stored thread to
/// restore.
///
/// A wrapper rather than conforming String to Identifiable: that conformance would be
/// app-wide and would quietly change how every other `ForEach` and `sheet(item:)` over
/// strings behaves.
struct AIOpening: Identifiable, Hashable {
    let id = UUID()
    /// Sent automatically on arrival. Empty when restoring a thread.
    var prompt: String = ""
    /// Set when reopening a stored conversation.
    var threadID: String?
}

private extension View {
    /// The reference uses `scrollEdgeEffectStyle(.soft, for: .top)`, which is iOS 26 only.
    /// The app ships to iOS 18, so it is applied where available and skipped elsewhere —
    /// it is a finish, not a layout, and its absence costs nothing structural.
    @ViewBuilder
    func softTopEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

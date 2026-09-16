//
//  DraggableChatGrid.swift
//  Voiid
//
//  Home-screen-style chat grid: tap a card opens the chat; HOLDING a card for five
//  seconds fills a border around it and then opens an actions sheet (pin, star, delete).
//
//  ── WHY HOLD-AND-SHEET REPLACED DRAG-TO-REORDER ─────────────────────────────────
//
//  Dragging a tile to a new position was never persisted. The grid is rebuilt from
//  SQLite on every refresh (ChatStore.applyLocalConversations), ordered by recency, so
//  a rearrangement that lived only in the in-memory array was discarded the moment
//  anything refreshed — opening a chat and coming back was enough. It looked like a
//  reordering bug; it was a feature that never had storage behind it.
//
//  Order now belongs to the data: recency, with pinned chats above it. Pinning is the
//  explicit, durable version of what dragging was gesturing at.
//
//  The five-second hold is long on purpose. This grid sits under a horizontal tab pager,
//  and a short press that arms on a moving finger is exactly what let one fast swipe both
//  pick up a tile and turn the page. A hold that requires the finger to STAY PUT cannot be
//  confused with a swipe, and the filling border says how long is left rather than leaving
//  the user to discover the threshold.
//

import SwiftUI

struct DraggableChatGrid: View {
    @Binding var items: [VConversation]
    var onOpen: (VConversation) -> Void
    var onCall: (VConversation) -> Void
    var onDelete: (VConversation) -> Void
    /// Pin/unpin and star/unstar, persisted by the store.
    var onPin: (VConversation) -> Void = { _ in }
    var onStar: (VConversation) -> Void = { _ in }

    /// The card currently being held, and how far through the hold it is (0...1).
    @State private var holding: VConversation?
    @State private var holdProgress: CGFloat = 0
    @State private var holdStart: Date?
    /// The card whose actions sheet is open.
    @State private var sheetItem: VConversation?
    @State private var gridWidth: CGFloat = 0

    /// How long the finger must stay down before the actions sheet appears.
    private static let holdDuration: TimeInterval = 5
    /// How far the finger may stray before the hold is abandoned. Generous enough for a
    /// resting thumb's natural drift, tight enough that a deliberate swipe cancels.
    private static let holdSlop: CGFloat = 12

    // EXACTLY THREE COLUMNS, 18pt gutters — the reference's grid.
    //
    // `.adaptive(88...104)` let the column count float with screen width: a Pro Max drew
    // four columns and an SE three, so the home screen was a different layout per device
    // and the card proportions changed with it. Three flexible columns give every device
    // the same composition and let the tile grow with the screen instead of multiplying.
    private let columns = [GridItem(.flexible(), spacing: 18),
                           GridItem(.flexible(), spacing: 18),
                           GridItem(.flexible(), spacing: 18)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { conv in
                    cell(conv)
                }
            }
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.top, VoiidSpacing.lg)
            .padding(.bottom, 110)
        }
        .coordinateSpace(name: "grid")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            gridWidth = width
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: items)
        // The hold's progress is driven here rather than by a Timer per cell: one clock for
        // the whole grid, and it stops existing the moment no card is held.
        .modifier(HoldClock(active: holding != nil, onTick: tick))
        .confirmationDialog(sheetItem?.title ?? "", isPresented: Binding(
            get: { sheetItem != nil },
            set: { if !$0 { sheetItem = nil } }
        ), titleVisibility: .visible) {
            if let conv = sheetItem {
                Button(conv.pinnedAt == nil ? "Pin" : "Unpin") { onPin(conv) }
                Button(conv.isStarred ? "Remove Star" : "Star") { onStar(conv) }
                Button("Call") { onCall(conv) }
                Button("Delete Chat", role: .destructive) { onDelete(conv) }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    /// Advance the active hold, and fire once it completes.
    private func tick() {
        guard let conv = holding, let start = holdStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        holdProgress = min(1, CGFloat(elapsed / Self.holdDuration))
        guard elapsed >= Self.holdDuration else { return }
        // Clear the hold BEFORE presenting: the finger is still down, and leaving the
        // border filled behind the sheet reads as though it is still counting.
        holding = nil
        holdStart = nil
        holdProgress = 0
        Haptics.success()
        sheetItem = conv
    }

    // MARK: a cell — tap opens; a five-second hold opens the actions sheet.
    private func cell(_ conv: VConversation) -> some View {
        let held = holding?.id == conv.id
        return cardView(conv)
            .overlay(holdBorder(for: conv))
            .contentShape(Rectangle())
            .scaleEffect(held ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: held)
            .onTapGesture { if holding == nil { Haptics.tap(); onOpen(conv) } }
            // A 0-distance drag is the only way to observe touch-down and touch-up without
            // claiming the gesture from the scroll view or the tab pager: SwiftUI hands this
            // one over the moment either of them recognises real movement, which is exactly
            // when the hold should be abandoned anyway.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if holding?.id != conv.id {
                            guard value.translation == .zero else { return }   // began, not a swipe
                            holding = conv
                            holdStart = Date()
                            holdProgress = 0
                            Haptics.tap()
                            return
                        }
                        // Moved too far: this is a scroll or a page swipe, not a hold.
                        if hypot(value.translation.width, value.translation.height) > Self.holdSlop {
                            cancelHold()
                        }
                    }
                    .onEnded { _ in cancelHold() }
            )
    }

    private func cancelHold() {
        guard holding != nil else { return }
        holding = nil
        holdStart = nil
        withAnimation(.easeOut(duration: 0.18)) { holdProgress = 0 }
    }

    /// The border that fills over the five seconds of a hold — the affordance that tells
    /// the user something is happening and roughly how much longer it needs.
    @ViewBuilder
    private func holdBorder(for conv: VConversation) -> some View {
        if holding?.id == conv.id {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .trim(from: 0, to: holdProgress)
                .stroke(VoiidColor.primary,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))   // start the fill at the top, not the right
                .animation(.linear(duration: 0.05), value: holdProgress)
                .allowsHitTesting(false)
        }
    }

    // MARK: card visual (shared by grid cell + floating drag)
    private func cardView(_ conv: VConversation) -> some View {
        ZStack(alignment: .bottom) {
            // THE PHOTO IS THE CARD.
            //
            // This drew a square photo tile with the title as a caption BELOW it. The
            // reference gives the image the whole card and floats everything on top, and
            // its note gives the reason: the reading order is image → name → unread → time
            // → status, and that order is enforced by letting the picture own the tile.
            ZStack {
                VoiidColor.fieldFill
                if conv.type == .self {
                    // NOTE TO SELF gets its own mark, not a profile photo. It is the one
                    // chat with no other person in it, and rendering your own face there
                    // reads as a conversation with someone else.
                    VoiidColor.primary.opacity(0.12)
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(VoiidColor.primary)
                } else {
                    GridPeerImage(photoURL: conv.photoURL, photoName: conv.photoName)
                }
            }

            // Without this the white name sits on whatever the photo happens to be and is
            // unreadable on a light frame. Bottom-weighted so it darkens the label area
            // without dimming the face above it.
            LinearGradient(
                colors: [.clear, .black.opacity(0.15), .black.opacity(0.82)],
                startPoint: .top, endPoint: .bottom
            )

            HStack(spacing: 4) {
                // THE FULL NAME, over up to two lines — what the reference renders
                // ("Ananya Sharma" in its own sample). One line is the intent; the second
                // exists so a long group name is shortened by the scale factor rather than
                // truncated with an ellipsis.
                Text(conv.title)
                    .font(VoiidFont.rounded(13.5, .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)

                // Replaces the word "Online" entirely, and pairs with the tile's border —
                // the border is visible at a glance across the grid, the dot confirms it
                // next to the name you are actually reading.
                if conv.isOnline {
                    Circle()
                        .fill(VoiidColor.accent)
                        .frame(width: 7, height: 7)
                }

                Spacer(minLength: 0)
            }
            // Clears the unread badge in the opposite corner.
            .padding(.trailing, conv.unreadCount > 0 ? 26 : 0)
            .padding(.horizontal, 9)
            .padding(.bottom, 9)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        // Pin and star live in the one free corner — the time owns top-trailing and the
        // unread badge owns bottom-trailing. Small and low-contrast on purpose: these are
        // states you set deliberately and then want to recognise at a glance, not signals
        // competing with unread for attention.
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                if conv.pinnedAt != nil {
                    Image(systemName: "pin.fill")
                        .rotationEffect(.degrees(45))
                }
                if conv.isStarred {
                    Image(systemName: "star.fill")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.95))
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .padding(.leading, 9)
            .padding(.top, 9)
        }
        .overlay(alignment: .topTrailing) {
            if let at = conv.lastMessageAt {
                // The SAME formatter the list row uses, so one conversation reads
                // identically in either layout.
                Text(VoiidDate.listPreview(at))
                    .font(VoiidFont.rounded(11, .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .padding(.horizontal, 9)
                    .padding(.top, 9)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if conv.unreadCount > 0 {
                Text(conv.unreadCount > 99 ? "99+" : "\(conv.unreadCount)")
                    .font(VoiidFont.rounded(11, .bold))
                    // textOnAccent, NOT textOnPrimary — the latter flips to near-white in
                    // light mode, where it measured 3.31:1 on the accent fill.
                    .foregroundColor(VoiidColor.textOnAccent)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.horizontal, 6)
                    .frame(minWidth: 21, minHeight: 21)
                    .background(Capsule().fill(VoiidColor.accent))
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        // ONE SIGNAL, ONE MEANING: the border means online. Unread is the badge, and the
        // time is the time. Offline draws NO border rather than a grey one — a neutral ring
        // on every other card is still a ring, and the accent stops standing out.
        //
        // Replaces a 12pt green dot in the tile's corner, which competed with the badge for
        // the same reading.
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(conv.isOnline ? VoiidColor.accent : .clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: conv.unreadCount)
    }

}

/// Square peer image for a chat-grid card. Resolves the peer's `photoURL` (an R2 object key
/// or an absolute URL) through the shared AvatarCache — instant on a cache hit — and falls
/// back to a bundled asset, then the Voiid wordmark.
private struct GridPeerImage: View {
    let photoURL: String?
    let photoName: String?
    @State private var resolved: UIImage?

    var body: some View {
        // GeometryReader gives the image an explicit box to fill.
        //
        // `scaledToFill()` alone sizes from the image's INTRINSIC dimensions and only then
        // fills, so a 3000px upload rendered at 3000px and spilled far outside the tile — the
        // "full profile image instead of the square" bug. Pinning an exact frame and clipping
        // to it is what actually constrains it; the parent's clipShape runs too late to help,
        // because the oversized image has already claimed the layout.
        GeometryReader { geo in
            Group {
                if let resolved {
                    Image(uiImage: resolved)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if let name = photoName, let ui = UIImage(named: name) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    // Sized RELATIVE to the tile, not a fixed 56pt: the grid is three columns
                    // of whatever the device is wide, so a constant looked oversized on an SE
                    // and lost on a Max.
                    BrandWordmark(size: geo.size.width * 0.18,
                                  color: VoiidColor.textSecondary,
                                  opacity: 0.22)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .task(id: photoURL) {
            if let hit = AvatarCache.cached(photoURL) { resolved = hit; return }
            resolved = await AvatarCache.resolve(photoURL)
        }
    }
}

/// Drives the hold countdown while a card is held, and owns no timer at all when none is.
///
/// A `TimelineView` would redraw the whole grid on every tick; a `Timer` left running would
/// keep firing after the finger lifts. This starts on the way in and invalidates on the way
/// out, so the cost is exactly the duration of a hold.
private struct HoldClock: ViewModifier {
    let active: Bool
    let onTick: () -> Void
    @State private var timer: Timer?

    func body(content: Content) -> some View {
        content.onChange(of: active) { _, isActive in
            timer?.invalidate()
            timer = nil
            guard isActive else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                Task { @MainActor in onTick() }
            }
        }
        .onDisappear { timer?.invalidate(); timer = nil }
    }
}

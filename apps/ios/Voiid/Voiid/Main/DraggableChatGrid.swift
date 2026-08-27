//
//  DraggableChatGrid.swift
//  Voiid
//
//  Home-screen-style chat grid: tap a card opens the chat; touch-and-drag
//  (immediate, no long-press) picks it up to reorder. Two side drop zones
//  appear while dragging — left = Call, right = Delete. Drop on a zone to fire.
//

import SwiftUI

struct DraggableChatGrid: View {
    @Binding var items: [VConversation]
    var onOpen: (VConversation) -> Void
    var onCall: (VConversation) -> Void
    var onDelete: (VConversation) -> Void

    @State private var dragItem: VConversation?
    @State private var dragOffset: CGSize = .zero
    @State private var dragStart: CGPoint = .zero      // touch start in grid space
    @State private var hoverZone: Zone? = nil
    @State private var cellCenters: [String: CGPoint] = [:]   // id -> center in grid space
    @State private var armed: VConversation? = nil     // long-press has "picked up" this card

    enum Zone { case call, delete }

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
        ZStack {
            // The grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { conv in
                        cell(conv)
                            .opacity(dragItem?.id == conv.id ? 0.001 : 1)   // hide original while dragging
                            .background(centerReader(conv))
                    }
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.top, VoiidSpacing.lg)
                .padding(.bottom, 110)
            }
            .scrollDisabled(dragItem != nil)   // lock scroll while dragging a card
            .coordinateSpace(name: "grid")

            // Side drop zones (only while dragging) — round icons, brand palette
            if dragItem != nil {
                HStack {
                    dropZone(.call, "phone.fill", "Call", VoiidColor.primary)
                    Spacer()
                    dropZone(.delete, "trash.fill", "Delete", VoiidColor.error)
                }
                .padding(.horizontal, VoiidSpacing.md)
                .transition(.scale.combined(with: .opacity))
                .allowsHitTesting(false)
            }

            // The floating dragged card
            if let d = dragItem {
                cardView(d)
                    .frame(width: 96)
                    .scaleEffect(1.12)
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
                    .position(x: dragStart.x + dragOffset.width, y: dragStart.y + dragOffset.height)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "grid")
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: items)
        .animation(.easeInOut(duration: 0.15), value: hoverZone)
    }

    // MARK: a cell — tap opens; long-press picks up, THEN drag reorders/zones.
    // (Vertical scroll keeps working because we only grab after the long-press fires.)
    private func cell(_ conv: VConversation) -> some View {
        cardView(conv)
            .contentShape(Rectangle())
            .scaleEffect(armed?.id == conv.id ? 1.08 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: armed?.id)
            .onTapGesture { if dragItem == nil { Haptics.tap(); onOpen(conv) } }
            .gesture(pickAndDrag(conv))
    }

    private func pickAndDrag(_ conv: VConversation) -> some Gesture {
        LongPressGesture(minimumDuration: 0.15)
            .onEnded { _ in
                Haptics.rigid(); armed = conv          // picked up
            }
            .sequenced(before:
                DragGesture(minimumDistance: 0, coordinateSpace: .named("grid"))
                    .onChanged { v in
                        guard armed?.id == conv.id else { return }
                        if dragItem == nil {
                            dragItem = conv
                            dragStart = cellCenters[conv.id] ?? v.startLocation
                        }
                        dragOffset = v.translation
                        let p = CGPoint(x: dragStart.x + v.translation.width, y: dragStart.y + v.translation.height)
                        updateHoverAndReorder(p, dragging: conv)
                    }
                    .onEnded { _ in
                        defer { dragItem = nil; dragOffset = .zero; hoverZone = nil; armed = nil }
                        guard let d = dragItem else { return }
                        switch hoverZone {
                        case .call:   Haptics.success(); onCall(d)
                        case .delete: Haptics.rigid();  onDelete(d)
                        case .none:   break
                        }
                    }
            )
    }

    // Hover detection for zones + live reorder
    private func updateHoverAndReorder(_ p: CGPoint, dragging conv: VConversation) {
        // zones: left/right 70pt gutters
        let w = VoiidScreen.width
        if p.x < 70 { hoverZone = .call; return }
        if p.x > w - 70 { hoverZone = .delete; return }
        hoverZone = nil
        // reorder: find nearest other cell center, swap order
        if let target = cellCenters
            .filter({ $0.key != conv.id })
            .min(by: { hypot($0.value.x - p.x, $0.value.y - p.y) < hypot($1.value.x - p.x, $1.value.y - p.y) }),
           hypot(target.value.x - p.x, target.value.y - p.y) < 60,
           let from = items.firstIndex(where: { $0.id == conv.id }),
           let to = items.firstIndex(where: { $0.id == target.key }), from != to {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                let m = items.remove(at: from); items.insert(m, at: to)
            }
        }
    }

    private func dropZone(_ zone: Zone, _ icon: String, _ label: String, _ color: Color) -> some View {
        let active = hoverZone == zone
        return VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 60, height: 60)
                    .overlay(Circle().stroke(VoiidColor.textOnPrimary.opacity(active ? 0.9 : 0), lineWidth: 2))
                    .shadow(color: color.opacity(active ? 0.5 : 0.25), radius: active ? 14 : 8, y: 4)
                Image(systemName: icon).font(.system(size: 24)).foregroundColor(VoiidColor.textOnPrimary)
            }
            Text(label)
                .font(VoiidFont.rounded(12, .semibold))
                .foregroundColor(color)
        }
        .opacity(active ? 1 : 0.85)
        .scaleEffect(active ? 1.2 : 1)
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

    // record each cell's center in grid space
    private func centerReader(_ conv: VConversation) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { cellCenters[conv.id] = CGPoint(x: g.frame(in: .named("grid")).midX, y: g.frame(in: .named("grid")).midY) }
                .onChange(of: g.frame(in: .named("grid"))) { _, f in cellCenters[conv.id] = CGPoint(x: f.midX, y: f.midY) }
        }
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

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

    // Smaller squares: cap card width so the avatars are a bit smaller with more spacing.
    private let columns = [GridItem(.adaptive(minimum: 88, maximum: 104), spacing: VoiidSpacing.lg)]

    var body: some View {
        ZStack {
            // The grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: VoiidSpacing.lg) {
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
        VStack(spacing: VoiidSpacing.sm) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous).fill(VoiidColor.fieldFill)
                    if conv.type == .self {
                        // NOTE TO SELF gets its own mark, not a profile photo. It is the one
                        // chat with no other person in it, and rendering your own face there
                        // reads as a conversation with someone else. A bookmark on brand tint
                        // says "saved" at a glance and is findable without reading the label.
                        RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                            .fill(VoiidColor.primary.opacity(0.12))
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(VoiidColor.primary)
                    } else {
                        // Show the peer's REAL profile photo (conv.photoURL is an R2 key or URL),
                        // resolved through the shared cache — falling back to a bundled asset, then
                        // the wordmark. Previously the grid only ever showed bundled/dummy assets.
                        GridPeerImage(photoURL: conv.photoURL, photoName: conv.photoName)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))

                // Badges sit INSIDE the tile. They were pushed OUT past its edge
                // (offset x: 6, y: -6), which broke the grid's alignment and let a badge
                // overlap the tile beside it. Online goes bottom-leading so the two can
                // never collide.
                if conv.isOnline {
                    Circle().fill(VoiidColor.success)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                if conv.unreadCount > 0 {
                    // Spark, not error-red: a count is not a failure state.
                    Text("\(conv.unreadCount)")
                        .font(VoiidFont.rounded(11, .bold))
                        // textOnAccent, NOT textOnPrimary — the latter flips to near-white in
                        // light mode, where it measured 3.31:1 on amber. Same fix as the
                        // static grid card and the list row; this is the drag layer's copy.
                        .foregroundColor(VoiidColor.textOnAccent)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(VoiidColor.accent)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(VoiidColor.background, lineWidth: 1.5))
                        .padding(5)
                }
            }
            Text(conv.title).font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.textPrimary).lineLimit(1)
        }
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
                    Image("VoiidWordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width * 0.52)
                        .opacity(0.22)
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

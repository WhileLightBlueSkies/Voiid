//
//  DraggableChatGrid.swift
//  Voiid
//
//  Home-screen-style chat grid. Tap opens the chat. A brief press picks a tile up and
//  drags it: onto another tile to rearrange, or out to the Call / Delete zones that appear
//  at the edges while a tile is in the air.
//
//  ── THE ARRANGEMENT IS DURABLE NOW ──────────────────────────────────────────────
//
//  Dragging used to do nothing lasting. The grid is rebuilt from SQLite on every refresh
//  (ChatStore.applyLocalConversations) ordered by recency, so a rearrangement that lived
//  only in the in-memory array was discarded the moment anything refreshed — opening a
//  chat and coming back was enough. `conversations.sort_index` is the storage it never
//  had: a manual order outranks recency and survives every sync.
//
//  ── WHY THE TAB PAGER HAS TO BE TOLD ────────────────────────────────────────────
//
//  This grid sits under a horizontal tab pager implemented as a UIKit pan on the hosting
//  controller (TabSwipeNavigation). UIKit cannot see SwiftUI gestures, so dragging a tile
//  sideways ALSO turned the page — which made rearranging into another column impossible
//  and put the Call/Delete zones, which live at the very edges, permanently out of reach.
//
//  So the grid announces a pickup through ChatPresence.isReorderingGrid and the pager
//  stands down for as long as a tile is held. That is the whole fix; the drag itself stays
//  immediate, the way it always was.
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

    /// Persist a manual arrangement. Nil order means "back to recency".
    var onReorder: ([String]) -> Void = { _ in }

    /// Picked up by the brief press, and now following the finger.
    @State private var armed: VConversation?
    @State private var dragItem: VConversation?
    @State private var dragOffset: CGSize = .zero
    @State private var dragStart: CGPoint = .zero
    /// Which side zone the dragged tile is currently over, if any.
    @State private var hoverZone: Zone?
    /// The tile whose dropdown is open. Set only when the three-second hold completes.
    @State private var menuItem: VConversation?
    /// Where the two zone circles actually are, measured from the rendered view. Hit-testing
    /// against these rather than against a screen-edge strip is what makes "drop ON the
    /// icon" mean what it says.
    @State private var zoneCenters: [Zone: CGPoint] = [:]
    /// A stationary press in progress, and how far through it is (0...1). At 1 the actions
    /// dropdown opens. Distinct from `armed`: a press that MOVES becomes a drag, a press
    /// that stays put becomes the menu.
    @State private var holding: VConversation?
    @State private var holdProgress: CGFloat = 0
    @State private var holdStart: Date?
    @State private var cellFrames: [String: CGRect] = [:]
    /// The same tiles in WINDOW space, for the tab pager's hit test. See publishTileFrames.
    @State private var windowFrames: [String: CGRect] = [:]
    @State private var cellCenters: [String: CGPoint] = [:]
    @State private var gridWidth: CGFloat = 0

    enum Zone { case call, delete }

    /// How long a stationary press takes to open the dropdown. Long enough that a drag
    /// never trips it by accident, short enough to feel like a deliberate second gesture
    /// rather than a wait.
    private static let holdDuration: TimeInterval = 3
    /// How far the finger may stray before the press stops counting as stationary and
    /// becomes a drag. A resting thumb wanders a few points; a deliberate move does not.
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
        // TWO COORDINATE SPACES, deliberately.
        //
        // "grid" is the SCROLLED content: tile centres live there and move with the list.
        // "gridFrame" is this stationary container: the Call/Delete circles live in an
        // overlay that does not scroll, so their centres belong here.
        //
        // Measuring both in "grid" is what made hovering a zone do nothing — scroll down a
        // row and the recorded circle positions were off by the scroll offset, so the
        // distance test never matched. `scrollOffset` bridges the two.
        ZStack {
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
        // A grid that disappears with a tile in the air (a tab switch, a push, the app
        // backgrounding) must not leave the pager disabled for the rest of the session.
        .onDisappear {
            ChatPresence.isReorderingGrid = false
            ChatPresence.gridTileFrames = []
        }
        .modifier(HoldClock(active: holding != nil, onTick: tick))
        // The side zones, only while a tile is actually in the air.
        .overlay {
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
        }
        .animation(.easeInOut(duration: 0.15), value: hoverZone)
        // The floating card, drawn at the finger.
        .overlay {
            if let d = dragItem {
                cardView(d)
                    .frame(width: 96)
                    .scaleEffect(1.12)
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
                    .position(x: dragStart.x + dragOffset.width, y: dragStart.y + dragOffset.height)
                    .allowsHitTesting(false)
            }
        }
        }
        .coordinateSpace(name: "gridFrame")
    }

    /// The actions dropdown, anchored to the card it belongs to.
    ///
    /// A contextMenu and NOT a confirmationDialog: the dialog slides up from the bottom of
    /// the screen as a modal sheet, which severs it from the tile it is about and covers
    /// the grid to say four words. A context menu grows out of the card under the finger,
    /// keeps that card visible as its own preview, and is the gesture iOS already teaches
    /// on the home screen — which is the layout this grid is imitating.
    @ViewBuilder
    private func actionsMenu(for conv: VConversation) -> some View {
        // `.white` on each label rather than a tint on the menu: a context menu renders its
        // rows with the system's own styling, and only an explicit foregroundStyle on the
        // label reaches the glyph. Delete keeps the destructive red — that colour IS the
        // warning, and whitening it would make the one irreversible action look like the
        // other three.
        Button { Haptics.tap(); onPin(conv) } label: {
            Label(conv.pinnedAt == nil ? "Pin" : "Unpin",
                  systemImage: conv.pinnedAt == nil ? "pin" : "pin.slash")
                .foregroundStyle(.white)
        }
        Button { Haptics.tap(); onStar(conv) } label: {
            Label(conv.isStarred ? "Remove Star" : "Star",
                  systemImage: conv.isStarred ? "star.slash" : "star")
                .foregroundStyle(.white)
        }
        Button { Haptics.tap(); onCall(conv) } label: {
            Label("Call", systemImage: "phone")
                .foregroundStyle(.white)
        }
        Divider()
        Button(role: .destructive) { Haptics.rigid(); onDelete(conv) } label: {
            Label("Delete Chat", systemImage: "trash")
        }
    }

    // MARK: a cell — tap opens; a brief press picks it up to drag.
    private func cell(_ conv: VConversation) -> some View {
        cardView(conv)
            .opacity(dragItem?.id == conv.id ? 0.001 : 1)   // the floating copy stands in
            .contentShape(Rectangle())
            .scaleEffect(armed?.id == conv.id ? 1.08 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: armed?.id)
            .background(GeometryReader { g in
                Color.clear
                    // Measured in the STATIONARY space, the same one the zones and the
                    // drag report in. In the scrolled space these three disagreed the
                    // moment the list moved, which is why hovering a zone did nothing.
                    .onAppear {
                        let f = g.frame(in: .named("gridFrame"))
                        cellFrames[conv.id] = f
                        cellCenters[conv.id] = CGPoint(x: f.midX, y: f.midY)
                        windowFrames[conv.id] = g.frame(in: .global)
                        publishTileFrames()
                    }
                    .onChange(of: g.frame(in: .named("gridFrame"))) { _, f in
                        cellFrames[conv.id] = f
                        cellCenters[conv.id] = CGPoint(x: f.midX, y: f.midY)
                        windowFrames[conv.id] = g.frame(in: .global)
                        publishTileFrames()
                    }
            })
            .overlay(holdBorder(for: conv))
            // A POPOVER WE CONTROL, opened by our own three-second hold.
            //
            // Not `contextMenu`: its long press is fixed at roughly half a second and there
            // is no API to retime it, so it both fired far too early and claimed the touch
            // before a drag could begin. This is presented from `menuItem`, which only the
            // hold clock sets — nothing competes for the gesture.
            //
            // Styled to sit on `surfaceRaised` with theme-aware labels so it reads like the
            // composer's attach menu rather than a bare system sheet.
            .popover(isPresented: Binding(
                get: { menuItem?.id == conv.id },
                set: { if !$0 { menuItem = nil } }
            ), attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    menuRow(conv.pinnedAt == nil ? "Pin" : "Unpin",
                            conv.pinnedAt == nil ? "pin" : "pin.slash") { onPin(conv) }
                    menuRow(conv.isStarred ? "Remove Star" : "Star",
                            conv.isStarred ? "star.slash" : "star") { onStar(conv) }
                    menuRow("Call", "phone") { onCall(conv) }
                    Divider().padding(.horizontal, 10)
                    menuRow("Delete Chat", "trash", destructive: true) { onDelete(conv) }
                }
                .padding(.vertical, 6)
                .frame(width: 230)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(VoiidColor.surfaceRaised)
            }
            .onTapGesture { if dragItem == nil { Haptics.tap(); onOpen(conv) } }
            .gesture(pickAndDrag(conv))
    }

    /// A brief press picks the tile up, then the drag moves it. Unchanged in feel from the
    /// grid this replaced — the press is what separates "I am moving this" from a scroll or
    /// a page swipe, and 0.15s is short enough to feel immediate.
    private func pickAndDrag(_ conv: VConversation) -> some Gesture {
        // ONE gesture, and it requires MOVEMENT to claim the touch.
        //
        // The previous version led with a LongPressGesture, which claimed every touch the
        // moment it landed — so the context menu's own long press never got to run and the
        // dropdown never appeared. Worse, an earlier attempt to attach the menu only while
        // nothing was dragging deadlocked: that condition could only become true after a
        // pickup the menu's recogniser was itself preventing.
        //
        // minimumDistance 8 settles it without a flag. A finger that MOVES is dragging; a
        // finger that stays put belongs to the menu. The system arbitrates, not us.
        DragGesture(minimumDistance: 0, coordinateSpace: .named("gridFrame"))
            .onChanged { v in
                // TOUCH-DOWN starts the three-second clock. minimumDistance is 0 so this
                // fires immediately: the drag has to be instant, so it cannot wait for a
                // movement threshold, and the hold has to start now or three seconds would
                // not begin counting until the finger moved.
                if holding?.id != conv.id && dragItem == nil {
                    holding = conv
                    holdStart = Date()
                    holdProgress = 0
                    // THE PAGER STANDS DOWN ON TOUCH-DOWN, not on first movement.
                    //
                    // UIKit asks gestureRecognizerShouldBegin at the FIRST movement of a
                    // touch. Setting this after `guard moved > 0` was always one instant
                    // too late: by then the pan had already been allowed to begin and the
                    // page was sliding. A finger resting on a tile is the last moment we
                    // can still refuse, so we refuse there.
                    ChatPresence.isReorderingGrid = true
                }
                // A finger that MOVES is dragging, not asking for the menu.
                let moved = hypot(v.translation.width, v.translation.height)
                if moved > Self.holdSlop { cancelHold() }
                guard moved > 0 || dragItem != nil else { return }
                if dragItem?.id != conv.id {
                    Haptics.rigid()
                    armed = conv
                    dragItem = conv
                    dragStart = cellCenters[conv.id] ?? v.startLocation
                }
                dragOffset = v.translation
                let p = CGPoint(x: dragStart.x + v.translation.width,
                                y: dragStart.y + v.translation.height)
                updateHoverAndReorder(p, dragging: conv)
            }
            .onEnded { _ in
                let dropped = hoverZone
                let moved = dragItem
                dragItem = nil
                dragOffset = .zero
                hoverZone = nil
                armed = nil
                cancelHold()
                ChatPresence.isReorderingGrid = false
                guard let d = moved else { return }
                switch dropped {
                case .call:   Haptics.success(); onCall(d)
                case .delete: Haptics.rigid();   onDelete(d)
                case .none:
                    // Persist on drop: one write per arrangement, not per swap.
                    onReorder(items.map(\.id))
                }
            }
    }

    /// Advance a stationary press; at full duration the dropdown opens.
    private func tick() {
        guard let conv = holding, let start = holdStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        holdProgress = min(1, CGFloat(elapsed / Self.holdDuration))
        guard elapsed >= Self.holdDuration else { return }
        cancelHold()
        // Release the tile before presenting: a card left scaled up and pager-locked behind
        // an open menu reads as still being dragged.
        armed = nil
        dragItem = nil
        dragOffset = .zero
        ChatPresence.isReorderingGrid = false
        Haptics.success()
        menuItem = conv
    }

    private func cancelHold() {
        guard holding != nil else { return }
        holding = nil
        holdStart = nil
        withAnimation(.easeOut(duration: 0.18)) { holdProgress = 0 }
    }

    /// Hand the tab pager the tiles' window rectangles.
    ///
    /// The pager is a UIKit pan and cannot see SwiftUI gestures, so it decides using where
    /// a touch STARTED. A flag alone lost the race on a fast flick — UIKit asks its
    /// recogniser to begin before SwiftUI delivers the first onChanged — and geometry known
    /// in advance cannot be late.
    private func publishTileFrames() {
        ChatPresence.gridTileFrames = Array(windowFrames.values)
    }

    /// One row of the dropdown, matching the metrics of a system menu row.
    private func menuRow(_ title: String, _ icon: String,
                         destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button {
            if destructive { Haptics.rigid() } else { Haptics.tap() }
            menuItem = nil
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22)
                Text(title).font(VoiidFont.rounded(16, .regular))
                Spacer(minLength: 0)
            }
            // textPrimary, NOT white: surfaceRaised is white in light mode, where white
            // labels would be invisible. Delete keeps the destructive red — that colour is
            // the warning, and whitening it would flatten the one irreversible action into
            // the other three.
            .foregroundStyle(destructive ? VoiidColor.error : VoiidColor.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Side zones first, then live reordering.
    private func updateHoverAndReorder(_ p: CGPoint, dragging conv: VConversation) {
        let w = gridWidth
        guard w > 0 else { return }
        // DROP ON THE ICON, not merely on that side of the screen.
        //
        // This used to be `p.x < 70` — the entire left strip, top to bottom — so a tile
        // dragged anywhere near the left margin called someone, and the right margin
        // deleted a chat, whether or not the icon was anywhere near the finger. Now the
        // test is distance to the circle the user can actually see, with a small margin
        // beyond its 60pt frame so the target is forgiving without being invisible.
        let zone: Zone? = zoneCenters.first { _, c in
            hypot(c.x - p.x, c.y - p.y) < 52
        }?.key
        if zone != hoverZone {
            hoverZone = zone
            if zone != nil { Haptics.tap() }   // the edge announces itself
        }
        guard zone == nil else { return }

        // SWAP ONLY WELL INSIDE ANOTHER TILE, not merely nearest to one.
        //
        // The test was "within 60pt of the nearest centre", which is true almost everywhere
        // on a three-column grid — so tiles reshuffled continuously as the finger crossed
        // the board and the arrangement churned under the drag. 34pt is roughly the inner
        // third of a tile: you have to actually be ON a neighbour to displace it, and
        // travelling past one leaves it alone.
        // A TILE ONLY SWAPS WITH ITS OWN KIND — pinned with pinned, unpinned with unpinned.
        //
        // The rule is about WHO IS BEING DRAGGED, not about pins being untouchable. Move a
        // pinned chat and it rearranges freely among the other pinned ones; move an
        // unpinned chat past a pin and the pin stays exactly where it is, because a
        // neighbour's drag is not permission to move it.
        //
        // Crossing the boundary is refused because the query sorts every pinned chat above
        // every unpinned one: a tile dragged across it would spring back on the next read,
        // so allowing the swap would show an arrangement the storage cannot keep. Pinning
        // and unpinning is how a chat changes blocks, and that is one deliberate action
        // rather than an accident of a drag.
        let draggedIsPinned = conv.pinnedAt != nil
        let sameBlock = Set(items.filter { ($0.pinnedAt != nil) == draggedIsPinned }.map(\.id))
        guard let from = items.firstIndex(where: { $0.id == conv.id }),
              let target = cellCenters
                  .filter({ $0.key != conv.id && sameBlock.contains($0.key) })
                  .min(by: { hypot($0.value.x - p.x, $0.value.y - p.y)
                           < hypot($1.value.x - p.x, $1.value.y - p.y) }),
              hypot(target.value.x - p.x, target.value.y - p.y) < 34,
              let to = items.firstIndex(where: { $0.id == target.key }), from != to
        else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            let m = items.remove(at: from)
            items.insert(m, at: to)
        }
    }

    private func dropZone(_ zone: Zone, _ icon: String, _ label: String, _ color: Color) -> some View {
        let active = hoverZone == zone
        return VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 60, height: 60)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear {
                                let f = g.frame(in: .named("gridFrame"))
                                zoneCenters[zone] = CGPoint(x: f.midX, y: f.midY)
                            }
                            .onChange(of: g.frame(in: .named("gridFrame"))) { _, f in
                                zoneCenters[zone] = CGPoint(x: f.midX, y: f.midY)
                            }
                    })
                    .overlay(Circle().stroke(VoiidColor.textOnPrimary.opacity(active ? 0.9 : 0), lineWidth: 2))
                    .shadow(color: color.opacity(active ? 0.5 : 0.25), radius: active ? 14 : 8, y: 4)
                Image(systemName: icon).font(.system(size: 24)).foregroundColor(VoiidColor.textOnPrimary)
            }
            // White, like the glyph above it, rather than the zone's own colour. The circle
            // already carries the colour; repeating it in the label made the word compete
            // with the target instead of naming it, and red-on-dark was the weakest text on
            // the screen at the moment the user most needs to read it.
            Text(label)
                .font(VoiidFont.rounded(12, .semibold))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        }
        .opacity(active ? 1 : 0.85)
        .scaleEffect(active ? 1.2 : 1)
    }

    /// The border that fills over the five seconds of a hold — the affordance that tells
    /// the user something is happening and roughly how much longer it needs.
    @ViewBuilder
    private func holdBorder(for conv: VConversation) -> some View {
        if holding?.id == conv.id {
            ZStack {
                // A dim wash so the fill reads against a bright photo. The card IS the
                // image, so a stroke alone competes with whatever is underneath it.
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black.opacity(0.28 * holdProgress))
                // The track, so the ring reads as "filling" rather than "a line appeared".
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 3)
                // RADIUS 24, matching the card's own clipShape. At 22 it sat a couple of
                // points inside the artwork and read as a misaligned box rather than the
                // edge of the tile lighting up.
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .trim(from: 0, to: holdProgress)
                    .stroke(Color.white,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))   // start at the top, not the right
            }
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

/// Applies a context menu ONLY while `active`, recogniser included.
///
/// SwiftUI has no way to remove `.contextMenu` by returning an empty menu — the modifier
/// installs a long-press recogniser regardless, and that recogniser claims touches from any
/// drag underneath it. Branching on the whole modifier is the only way to get the gesture
/// back, and `@ViewBuilder` keeps both branches the same concrete view tree.
private struct ConditionalContextMenu<MenuContent: View>: ViewModifier {
    let active: Bool
    @ViewBuilder var menu: () -> MenuContent

    func body(content: Content) -> some View {
        if active { content.contextMenu { menu() } } else { content }
    }
}

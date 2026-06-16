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

    enum Zone { case call, delete }

    private let columns = [GridItem(.flexible(), spacing: VoiidSpacing.md),
                           GridItem(.flexible(), spacing: VoiidSpacing.md),
                           GridItem(.flexible(), spacing: VoiidSpacing.md)]

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

            // Side drop zones (only while dragging)
            if dragItem != nil {
                HStack {
                    dropZone(.call, "phone.fill", "Call", VoiidColor.success)
                    Spacer()
                    dropZone(.delete, "trash.fill", "Delete", VoiidColor.error)
                }
                .padding(.horizontal, VoiidSpacing.sm)
                .transition(.opacity)
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

    // MARK: a normal cell with the immediate drag gesture
    private func cell(_ conv: VConversation) -> some View {
        cardView(conv)
            .contentShape(Rectangle())
            .onTapGesture { if dragItem == nil { Haptics.tap(); onOpen(conv) } }
            .gesture(dragGesture(conv))
    }

    private func dragGesture(_ conv: VConversation) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("grid"))
            .onChanged { v in
                if dragItem == nil {
                    Haptics.soft()
                    dragItem = conv
                    dragStart = cellCenters[conv.id] ?? v.startLocation
                }
                dragOffset = v.translation
                let p = CGPoint(x: dragStart.x + v.translation.width, y: dragStart.y + v.translation.height)
                updateHoverAndReorder(p, dragging: conv)
            }
            .onEnded { _ in
                defer { dragItem = nil; dragOffset = .zero; hoverZone = nil }
                guard let d = dragItem else { return }
                switch hoverZone {
                case .call:   Haptics.success(); onCall(d)
                case .delete: Haptics.rigid();  onDelete(d)
                case .none:   break   // reorder already applied live
                }
            }
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
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 24))
            Text(label).font(VoiidFont.rounded(11, .semibold))
        }
        .foregroundColor(.white)
        .frame(width: 64, height: 80)
        .background(color.opacity(hoverZone == zone ? 1 : 0.65))
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .scaleEffect(hoverZone == zone ? 1.15 : 1)
    }

    // MARK: card visual (shared by grid cell + floating drag)
    private func cardView(_ conv: VConversation) -> some View {
        VStack(spacing: VoiidSpacing.sm) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous).fill(VoiidColor.fieldFill)
                    if let name = conv.photoName, let ui = UIImage(named: name) {
                        Image(uiImage: ui).resizable().scaledToFill()
                    } else {
                        Image("VoiidWordmark").resizable().scaledToFit().frame(width: 56).opacity(0.22)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
                if conv.isOnline {
                    Circle().fill(VoiidColor.success).frame(width: 13, height: 13)
                        .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2)).offset(x: -6, y: 6)
                }
                if conv.unreadCount > 0 {
                    Text("\(conv.unreadCount)").font(VoiidFont.rounded(11, .bold)).foregroundColor(.white)
                        .frame(minWidth: 20, minHeight: 20).background(VoiidColor.error).clipShape(Circle())
                        .offset(x: 6, y: -6)
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

//
//  ClipEditorScreen.swift
//  Voiid
//
//  Step 2 of posting a clip: the editor. Built to the Voiid Ui reference
//  (Chat/ClipEditScreen.swift) over the real preview player and exporter (ClipEditor.swift).
//
//  ── THE CLIP IS THE SCREEN ──────────────────────────────────────────────────────
//  Same frame as the recorder: the clip plays full-bleed and loops, and the tools sit in the
//  same right-hand column — Text, Trim, Filters, Cover, Sound — so going from recording to
//  editing is the same place with different buttons. Trim, Filters and Cover open as a tray
//  from the bottom with the clip still in view above it; text is typed over the clip, dragged
//  where it goes, and dragged onto the bin to delete.
//
//  ── TEXT IS LAID OUT ON THE VIDEO, NOT THE SCREEN ───────────────────────────────
//  The video fills the screen, so its edges are cropped off. Text positions are fractions
//  of the VIDEO frame (ClipTextOverlay), placed here inside the video's on-screen rect, so
//  what you see is where the export burns it in — not shifted by the crop.
//

import SwiftUI
import PhotosUI
import AVFoundation

enum ClipEditPanel: Equatable { case trim, filters, cover }

struct ClipEditorScreen: View {
    let sourceURL: URL
    @Binding var edit: ClipEdit
    /// Set by Post's "Edit cover" so the editor opens straight on the cover picker.
    @Binding var openPanel: ClipEditPanel?
    var onBack: () -> Void
    var onNext: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preview = ClipPreviewPlayer()

    @State private var loaded = false
    @State private var duration: Double = 0
    /// The video's upright size, for laying text out on it.
    @State private var videoSize = CGSize(width: 1080, height: 1920)
    @State private var filmstrip: [UIImage] = []
    @State private var coverPreview: UIImage?
    @State private var coverRequest = 0
    @State private var filterThumbs: [ClipFilter: UIImage] = [:]
    @State private var coverPick: PhotosPickerItem?

    @State private var panel: ClipEditPanel?
    @State private var toast: String?

    @State private var typing: ClipTextOverlay?
    @State private var draggingText: UUID?
    @State private var dragOffset: CGSize = .zero
    @State private var overBin = false

    private var customCover: UIImage? { edit.customCoverJPEG.flatMap(UIImage.init(data:)) }

    /// The video's on-screen rect, measured on the full-screen canvas.
    @State private var canvas: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The canvas is the whole screen, edges included, so the rect text is laid out
            // in is the rect the video is actually drawn in.
            GeometryReader { geo in
                player(in: geo.size, rect: videoRect(in: geo.size))
            }
            .ignoresSafeArea()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { canvas = $0 }

            if typing == nil {
                chrome
                if panel != nil { tray }
            }

            if draggingText != nil { bin }

            if let typing {
                ClipTextComposer(item: typing, frameWidth: videoRect(in: canvas).width) { done in
                    finishTyping(done)
                }
            }

            if let toast {
                Text(toast)
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.keyboard)
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        // Pushing Post leaves this view alive in the stack, so `.task` never runs again —
        // pause on the way out and resume on the way back rather than releasing the player.
        .onAppear {
            if let openPanel {
                open(openPanel)
                self.openPanel = nil
            } else if loaded {
                preview.resume()
            }
        }
        .onDisappear { preview.pause() }
        .onChange(of: edit.filter) { _, f in
            Task {
                await preview.applyFilter(f, source: sourceURL)
                await refreshCoverPreview()
            }
        }
        .onChange(of: edit.muted) { _, m in preview.setMuted(m) }
        .onChange(of: edit.coverSeconds) { _, _ in Task { await refreshCoverPreview() } }
        .onChange(of: coverPick) { _, item in
            guard let item else { return }
            Task {
                await loadCustomCover(item)
                coverPick = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // A player left running behind a backgrounded app keeps decoding for nothing.
            if phase == .active, panel != .cover { preview.resume() } else { preview.pause() }
        }
    }

    // MARK: Player

    private func player(in size: CGSize, rect: CGRect) -> some View {
        ZStack {
            ClipPlayerLayer(player: preview.player, gravity: .resizeAspectFill)
                .frame(width: size.width, height: size.height)

            // Choosing a cover shows THE COVER, still, as the grid will: the chosen frame with
            // its look, or the photo you picked.
            if panel == .cover, let still = customCover ?? coverPreview {
                Image(uiImage: still)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .transition(.opacity)
            }

            if !loaded {
                ClipShimmer().frame(width: size.width, height: size.height)
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if panel != nil { closePanel(); return }
                    Haptics.tap()
                    preview.togglePlayback()
                }

            // Text sits on the video frame, where it will be burned in.
            ForEach(edit.texts) { item in
                ClipTextLabel(item: item, frameWidth: rect.width)
                    .scaleEffect(draggingText == item.id && overBin ? 0.6 : 1)
                    .opacity(typing?.id == item.id ? 0 : (draggingText == item.id && overBin ? 0.5 : 1))
                    .gesture(textDrag(item, screen: size, rect: rect))
                    .onTapGesture {
                        Haptics.tap()
                        typing = item
                    }
                    .allowsHitTesting(panel == nil)
                    .position(x: rect.minX + item.position.x * rect.width,
                              y: rect.minY + item.position.y * rect.height)
                    .offset(draggingText == item.id ? dragOffset : .zero)
            }

            if loaded && !preview.isPlaying && panel == nil && typing == nil && draggingText == nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.white)
                    .frame(width: 76, height: 76)
                    .background(.ultraThinMaterial, in: Circle())
                    .environment(\.colorScheme, .dark)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.15), value: preview.isPlaying)
    }

    /// Where the aspect-filled video actually sits on screen, overflow included.
    private func videoRect(in size: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = max(size.width / videoSize.width, size.height / videoSize.height)
        let w = videoSize.width * scale, h = videoSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    // MARK: Chrome

    private var chrome: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    glassButton("chevron.left", label: "Back to camera") {
                        preview.pause()
                        onBack()
                    }
                    Spacer()
                    Text(Self.short(edit.duration))
                        .font(VoiidFont.rounded(13, .semibold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                    Spacer()
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer(minLength: 0)

                if panel == nil { bottomBar.transition(.opacity) }
            }

            toolColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 12)
                .padding(.top, 70)
                .opacity(panel == nil ? 1 : 0)
                .allowsHitTesting(panel == nil)
        }
        .animation(.easeOut(duration: 0.2), value: panel)
    }

    private var toolColumn: some View {
        VStack(spacing: 14) {
            tool("textformat", "Text") {
                preview.pause()
                typing = ClipTextOverlay(text: "")
            }
            tool("scissors", "Trim", active: duration > 0 && edit.duration < min(duration, ClipCaps.maxDurationSeconds) - 0.05) {
                open(.trim)
            }
            tool("camera.filters", edit.filter == .none ? "Filters" : edit.filter.label,
                 active: edit.filter != .none) { open(.filters) }
            tool("photo", "Cover", active: edit.customCoverJPEG != nil) { open(.cover) }
            tool(edit.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                 edit.muted ? "Muted" : "Sound", active: edit.muted) {
                edit.muted.toggle()
                flash(edit.muted ? "Sound off" : "Sound on")
            }
        }
    }

    /// Playback progress within the trim, the cover you are posting with, and Next.
    private var bottomBar: some View {
        VStack(spacing: 14) {
            GeometryReader { geo in
                let t = edit.duration > 0 ? (preview.position - edit.trimStart) / edit.duration : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white)
                        .frame(width: max(3, geo.size.width * min(1, max(0, t))))
                }
            }
            .frame(height: 3)

            HStack(spacing: 12) {
                Button {
                    Haptics.tap()
                    open(.cover)
                } label: {
                    HStack(spacing: 10) {
                        coverThumb
                            .frame(width: 34, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(.white.opacity(0.8), lineWidth: 1))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Cover")
                                .font(VoiidFont.rounded(13, .semibold))
                            Text("Tap to change")
                                .font(VoiidFont.rounded(11))
                                .opacity(0.7)
                        }
                        .foregroundColor(.white)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 14)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Change cover")

                Spacer()

                Button {
                    Haptics.success()
                    preview.pause()
                    onNext()
                } label: {
                    HStack(spacing: 6) {
                        Text("Next")
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                    }
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .padding(.horizontal, 24)
                    .frame(height: 48)
                    .background(Capsule().fill(VoiidColor.accent))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!loaded || edit.duration < 0.5)
                .opacity(!loaded || edit.duration < 0.5 ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .padding(.top, 50)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private var coverThumb: some View {
        if let still = customCover ?? coverPreview {
            Image(uiImage: still).resizable().scaledToFill()
        } else {
            ClipShimmer()
        }
    }

    // MARK: Tray

    private var tray: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 16) {
                Capsule().fill(.white.opacity(0.35)).frame(width: 36, height: 4).padding(.top, 8)

                Text(trayTitle)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(.white)

                switch panel {
                case .trim: trimPanel
                case .filters: filtersPanel
                case .cover: coverPanel
                case nil: EmptyView()
                }

                Button {
                    Haptics.tap()
                    closePanel()
                } label: {
                    Text("Done")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 28)
                        .frame(height: 42)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .transition(.move(edge: .bottom))
    }

    private var trayTitle: String {
        switch panel {
        case .trim: return "Trim"
        case .filters: return "Filters"
        case .cover: return "Choose a cover"
        case nil: return ""
        }
    }

    // MARK: Trim

    /// The whole source as a strip of frames; the kept range is framed, the rest dimmed.
    /// Dragging a handle parks the video on that frame, so you see exactly where it cuts.
    private var trimPanel: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                let d = max(duration, 0.1)
                let startX = w * edit.trimStart / d
                let endX = w * edit.trimEnd / d
                ZStack(alignment: .leading) {
                    strip(width: w, height: 56)

                    Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, startX), height: 56)
                    Rectangle().fill(.black.opacity(0.6))
                        .frame(width: max(0, w - endX), height: 56)
                        .offset(x: endX)

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(VoiidColor.accent, lineWidth: 3)
                        .frame(width: max(0, endX - startX), height: 56)
                        .offset(x: startX)
                        .allowsHitTesting(false)

                    Capsule().fill(.white)
                        .frame(width: 2, height: 64)
                        .offset(x: w * min(max(preview.position, 0), d) / d - 1)
                        .allowsHitTesting(false)

                    trimHandle
                        .offset(x: startX - 22)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                            .onChanged { v in
                                let t = min(max(0, v.location.x / w * d), edit.trimEnd - 1)
                                // Moving the start can pull a long window past the cap.
                                edit.trimStart = max(max(0, t), edit.trimEnd - ClipCaps.maxDurationSeconds)
                                preview.scrub(to: edit.trimStart)
                            }
                            .onEnded { _ in trimReleased() })
                    trimHandle
                        .offset(x: endX - 22)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                            .onChanged { v in
                                let t = max(min(d, v.location.x / w * d), edit.trimStart + 1)
                                edit.trimEnd = min(min(d, t), edit.trimStart + ClipCaps.maxDurationSeconds)
                                preview.scrub(to: edit.trimEnd)
                            }
                            .onEnded { _ in trimReleased() })
                }
                .coordinateSpace(.named("trim"))
            }
            .frame(height: 64)
            .padding(.horizontal, 24)

            HStack {
                Text(Self.clock(edit.trimStart))
                Spacer()
                Text("\(Self.short(edit.duration)) selected")
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
                Spacer()
                Text(Self.clock(edit.trimEnd))
            }
            .font(VoiidFont.rounded(12, .medium))
            .monospacedDigit()
            .foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 24)
        }
    }

    /// A 44-point touch target around a visible 22-point grip.
    private var trimHandle: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(VoiidColor.accent)
            .frame(width: 22, height: 64)
            .overlay(Capsule().fill(.white).frame(width: 3, height: 20))
            .frame(width: 44, height: 64)
            .contentShape(Rectangle())
    }

    private func trimReleased() {
        Haptics.selection()
        // Keep the cover inside what will actually be posted.
        edit.coverSeconds = min(max(edit.coverSeconds, edit.trimStart), max(edit.trimStart, edit.trimEnd - 0.1))
        preview.setLoop(start: edit.trimStart, end: edit.trimEnd)
    }

    // MARK: Filters

    private var filtersPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ClipFilter.allCases) { f in
                    let on = edit.filter == f
                    Button {
                        Haptics.selection()
                        edit.filter = f
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let thumb = filterThumbs[f] {
                                    Image(uiImage: thumb).resizable().scaledToFill()
                                } else {
                                    ClipShimmer()
                                }
                            }
                            .frame(width: 60, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(on ? VoiidColor.accent : .white.opacity(0.25), lineWidth: on ? 3 : 1))
                            Text(f.label)
                                .font(VoiidFont.rounded(11, on ? .bold : .medium))
                                .foregroundColor(.white.opacity(on ? 1 : 0.8))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(f.label)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Cover

    /// Slide the frame along the kept part of the clip, or pick a photo. The grid is made
    /// entirely of covers, so this is the choice that decides whether anyone taps the clip.
    private var coverPanel: some View {
        VStack(spacing: 14) {
            GeometryReader { geo in
                let w = geo.size.width
                let d = max(duration, 0.1)
                let boxW: CGFloat = 42
                let x = (w - boxW) * edit.coverSeconds / d
                ZStack(alignment: .leading) {
                    strip(width: w, height: 56)
                        .opacity(edit.customCoverJPEG == nil ? 1 : 0.35)
                    // What will not be posted is dimmed, so the cover cannot come from it.
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: max(0, w * edit.trimStart / d), height: 56)
                    Rectangle().fill(.black.opacity(0.55))
                        .frame(width: max(0, w - w * edit.trimEnd / d), height: 56)
                        .offset(x: w * edit.trimEnd / d)
                    if edit.customCoverJPEG == nil {
                        Group {
                            if let coverPreview {
                                Image(uiImage: coverPreview).resizable().scaledToFill()
                            } else {
                                ClipShimmer()
                            }
                        }
                        .frame(width: boxW, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .offset(x: x)
                        .allowsHitTesting(false)
                    }
                }
                .frame(height: 64)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    edit.customCoverJPEG = nil
                    let t = (v.location.x - boxW / 2) / max(1, w - boxW) * d
                    edit.coverSeconds = min(max(t, edit.trimStart), max(edit.trimStart, edit.trimEnd - 0.1))
                }.onEnded { _ in Haptics.selection() })
            }
            .frame(height: 64)
            .padding(.horizontal, 24)

            HStack(spacing: 10) {
                PhotosPicker(selection: $coverPick, matching: .images, photoLibrary: .shared()) {
                    Label(edit.customCoverJPEG == nil ? "From library" : "Change photo",
                          systemImage: "photo.on.rectangle")
                        .font(VoiidFont.rounded(13, .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Capsule().fill(.white.opacity(0.15)))
                }
                if edit.customCoverJPEG != nil {
                    Button {
                        Haptics.tap()
                        withAnimation(.easeOut(duration: 0.2)) { edit.customCoverJPEG = nil }
                    } label: {
                        Label("Use a frame", systemImage: "film")
                            .font(VoiidFont.rounded(13, .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Capsule().fill(.white.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The source as a strip of real frames, left to right.
    private func strip(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            if filmstrip.isEmpty {
                ClipShimmer()
            } else {
                ForEach(Array(filmstrip.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width / CGFloat(filmstrip.count), height: height)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Text

    private func textDrag(_ item: ClipTextOverlay, screen: CGSize, rect: CGRect) -> some Gesture {
        // Global space: the canvas is the whole screen, so the finger is compared against
        // the bin in the same coordinates it is drawn in.
        DragGesture(coordinateSpace: .global)
            .onChanged { v in
                if draggingText == nil { preview.pause() }
                draggingText = item.id
                dragOffset = v.translation
                let near = abs(v.location.x - screen.width / 2) < 50 && v.location.y > screen.height - 150
                if near != overBin {
                    overBin = near
                    if near { Haptics.selection() }
                }
            }
            .onEnded { v in
                if overBin {
                    Haptics.rigid()
                    withAnimation(.easeOut(duration: 0.2)) { edit.texts.removeAll { $0.id == item.id } }
                } else if let i = edit.texts.firstIndex(where: { $0.id == item.id }), rect.width > 0 {
                    // Kept inside the part of the video that is on screen.
                    let lowX = max(0, -rect.minX / rect.width) + 0.05
                    let highX = min(1, (screen.width - rect.minX) / rect.width) - 0.05
                    let lowY = max(0, -rect.minY / rect.height) + 0.06
                    let highY = min(1, (screen.height - rect.minY) / rect.height) - 0.08
                    let x = item.position.x + v.translation.width / rect.width
                    let y = item.position.y + v.translation.height / rect.height
                    edit.texts[i].position = CGPoint(x: min(highX, max(lowX, x)), y: min(highY, max(lowY, y)))
                }
                draggingText = nil
                dragOffset = .zero
                overBin = false
                preview.resume()
            }
    }

    private var bin: some View {
        VStack {
            Spacer()
            Image(systemName: "trash")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: overBin ? 64 : 52, height: overBin ? 64 : 52)
                .background(Circle().fill(overBin ? VoiidColor.error : .black.opacity(0.45)))
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                .padding(.bottom, 40)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: overBin)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func finishTyping(_ done: ClipTextOverlay) {
        withAnimation(.easeOut(duration: 0.2)) {
            let text = done.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = edit.texts.firstIndex(where: { $0.id == done.id }) {
                if text.isEmpty { edit.texts.remove(at: i) } else { edit.texts[i] = done }
            } else if !text.isEmpty {
                edit.texts.append(done)
            }
            typing = nil
        }
        preview.resume()
    }

    // MARK: Helpers

    private func tool(_ icon: String, _ label: String, active: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap(); action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(active ? .black : .white)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle().fill(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial))
                    )
                    .environment(\.colorScheme, .dark)
                Text(label)
                    .font(VoiidFont.rounded(10.5, .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }
            .frame(width: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    private func glassButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap(); action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    private func open(_ p: ClipEditPanel) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { panel = p }
        // The cover is a still: hold the video on it. The other trays keep it playing.
        if p == .cover { preview.hold(at: edit.coverSeconds) }
    }

    private func closePanel() {
        let was = panel
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { panel = nil }
        if was == .cover { preview.setLoop(start: edit.trimStart, end: edit.trimEnd) } else { preview.resume() }
    }

    private func flash(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeOut(duration: 0.2)) { if toast == text { toast = nil } }
        }
    }

    // MARK: Loading

    private func load() async {
        guard !loaded else { return }
        let asset = AVURLAsset(url: sourceURL)
        duration = (try? await asset.load(.duration))?.seconds ?? 0
        if edit.trimEnd <= 0 || edit.trimEnd > duration {
            edit.trimEnd = min(duration, edit.trimStart + ClipCaps.maxDurationSeconds)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let upright = natural.applying(transform)
            if abs(upright.width) > 0, abs(upright.height) > 0 {
                videoSize = CGSize(width: abs(upright.width), height: abs(upright.height))
            }
        }

        await preview.load(source: sourceURL, filter: edit.filter)
        preview.setMuted(edit.muted)
        preview.setLoop(start: edit.trimStart, end: edit.trimEnd)
        withAnimation(.easeOut(duration: 0.2)) { loaded = true }
        if panel == .cover { preview.hold(at: edit.coverSeconds) }

        await refreshCoverPreview()
        filmstrip = await ClipExporter.filmstrip(from: sourceURL, count: 12)
        await buildFilterThumbs()
    }

    /// Only the newest request lands, so dragging the cover never shows a frame it passed.
    private func refreshCoverPreview() async {
        coverRequest += 1
        let request = coverRequest
        let image = try? await ClipExporter.frame(from: sourceURL, at: edit.coverSeconds, filter: edit.filter)
        guard request == coverRequest, let image else { return }
        coverPreview = image
    }

    /// One decode, every look applied to it.
    private func buildFilterThumbs() async {
        guard let base = try? await ClipExporter.rawFrame(from: sourceURL, at: max(0.1, edit.trimStart)) else { return }
        let ci = CIImage(cgImage: base)
        let context = CIContext()
        for f in ClipFilter.allCases {
            let out = f.apply(to: ci)
            if let cg = context.createCGImage(out, from: ci.extent) {
                filterThumbs[f] = UIImage(cgImage: cg)
            }
        }
    }

    /// Re-encoded to a bounded JPEG: an 8 MB HEIC straight from the camera roll would be a
    /// far heavier grid tile than the frames it sits beside.
    private func loadCustomCover(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        let maxEdge: CGFloat = 1080
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if let jpeg = resized.jpegData(compressionQuality: 0.8) {
            withAnimation(.easeOut(duration: 0.2)) { edit.customCoverJPEG = jpeg }
            Haptics.success()
        }
    }

    static func clock(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    /// "18s", "1m 05s".
    static func short(_ s: Double) -> String {
        let whole = Int(s.rounded())
        return whole < 60 ? "\(whole)s" : String(format: "%dm %02ds", whole / 60, whole % 60)
    }
}

// MARK: - Text composer

/// Typing over a dimmed clip, the text large and centred; colour and background below.
/// Done places it — or drops it, if it was cleared.
private struct ClipTextComposer: View {
    @State var item: ClipTextOverlay
    let frameWidth: CGFloat
    var onDone: (ClipTextOverlay) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let font = ClipTextOverlay.font(forFrameWidth: frameWidth)
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { onDone(item) }

            VStack(spacing: 0) {
                HStack {
                    Button {
                        Haptics.tap()
                        item.style = item.style == .plain ? .pill : .plain
                    } label: {
                        Image(systemName: item.style == .plain ? "character" : "character.textbox")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .environment(\.colorScheme, .dark)
                    }
                    .accessibilityLabel(item.style == .plain ? "Add background" : "Remove background")
                    Spacer()
                    Button {
                        Haptics.tap()
                        onDone(item)
                    } label: {
                        Text("Done")
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 20)
                            .frame(height: 38)
                            .background(Capsule().fill(.white))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Spacer()

                TextField("", text: $item.text,
                          prompt: Text("Type something").foregroundColor(.white.opacity(0.5)),
                          axis: .vertical)
                    .focused($focused)
                    .font(Font(font))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color(item.ink))
                    .tint(VoiidColor.accent)
                    .padding(.horizontal, item.style == .pill ? font.pointSize * 0.5 : 0)
                    .padding(.vertical, item.style == .pill ? font.pointSize * 0.21 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: font.pointSize * 0.36, style: .continuous)
                            .fill(item.style == .pill ? Color(item.fill) : .clear)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
                    .onChange(of: item.text) { _, new in
                        // A caption on a clip, not an essay: long text would cover the video.
                        if new.count > 120 { item.text = String(new.prefix(120)) }
                    }

                Spacer()

                HStack(spacing: 14) {
                    ForEach(ClipTextOverlay.palette.indices, id: \.self) { i in
                        Button {
                            Haptics.selection()
                            item.color = i
                        } label: {
                            Circle()
                                .fill(Color(ClipTextOverlay.palette[i]))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(.white, lineWidth: item.color == i ? 3 : 1.5))
                                .scaleEffect(item.color == i ? 1.15 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(i + 1)")
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .onAppear { focused = true }
    }
}

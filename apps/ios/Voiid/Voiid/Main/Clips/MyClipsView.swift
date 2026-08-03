//
//  MyClipsView.swift
//  Voiid
//
//  "My clips" — the author's own grid, and the only place a clip can be managed.
//
//  Editing is deliberately limited to the CAPTION and the COVER. The video itself is
//  immutable: people have already watched, liked and commented on those bytes, and
//  swapping them under a stable id would silently turn every existing like into an
//  endorsement of something the audience never saw. Re-uploading is a new clip.
//

import SwiftUI
import PhotosUI
import AVFoundation

struct MyClipsView: View {
    @EnvironmentObject var engine: ClipsEngine

    @State private var editing: Clip?
    @State private var confirmingDelete: Clip?
    @State private var openIndex: Int?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        content
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("My clips")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if !engine.myHasLoadedOnce { await engine.refreshMine() }
            }
            .sheet(item: $editing) { clip in
                ClipEditSheet(clip: clip).environmentObject(engine)
            }
            // Destructive and irreversible, so it gets a real confirmation. The message
            // says what delete does NOT do — see the note in routes/clips.ts.
            .confirmationDialog(
                "Delete this clip?",
                isPresented: Binding(
                    get: { confirmingDelete != nil },
                    set: { if !$0 { confirmingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let clip = confirmingDelete {
                        Haptics.tap()
                        Task { await engine.deleteClip(clip.id) }
                    }
                    confirmingDelete = nil
                }
                Button("Cancel", role: .cancel) { confirmingDelete = nil }
            } message: {
                Text("This removes it from Clips. People who already watched or saved it may still have a copy.")
            }
    }

    @ViewBuilder
    private var content: some View {
        // The error state must win over the empty state — "You haven't posted a clip"
        // for a failed request is a lie about the user's own content.
        if let error = engine.myLoadError, engine.myClips.isEmpty {
            ScrollView {
                ClipsEmptyState(kind: .failed(error)) { Task { await engine.refreshMine() } }
            }
            .refreshable { await engine.refreshMine() }
        } else if engine.myLoading && engine.myClips.isEmpty {
            ScrollView { ClipsGridSkeleton().padding(.top, 2) }
                .disabled(true)
        } else if engine.myClips.isEmpty && engine.myHasLoadedOnce {
            ScrollView { ClipsEmptyState(kind: .noneFromYou) }
                .refreshable { await engine.refreshMine() }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(engine.myClips) { clip in
                    tile(clip)
                        .task { await engine.loadMoreMineIfNeeded(currentItem: clip) }
                }
            }
            .padding(.top, 2)

            Color.clear.frame(height: 100)
        }
        .refreshable { await engine.refreshMine() }
    }

    private func tile(_ clip: Clip) -> some View {
        ZStack(alignment: .bottomLeading) {
            ClipThumbnail(url: clip.thumbURL, localPath: clip.localThumbPath)
                .aspectRatio(9.0 / 16.0, contentMode: .fill)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .center, endPoint: .bottom)

            HStack(spacing: 3) {
                Image(systemName: "eye.fill").font(.system(size: 10))
                Text(ClipCount.compact(clip.viewCount))
                    .font(VoiidFont.rounded(11, .semibold))
            }
            .foregroundColor(.white)
            .shadow(radius: 2)
            .padding(6)
        }
        .contentShape(Rectangle())
        // Long-press for management, matching the platform idiom for "act on this item"
        // rather than hanging a permanent "..." button on every tile in a dense grid.
        .contextMenu {
            Button {
                Haptics.tap()
                editing = clip
            } label: {
                Label("Edit caption & cover", systemImage: "pencil")
            }
            Button(role: .destructive) {
                Haptics.tap()
                confirmingDelete = clip
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Edit sheet

/// Caption + cover editor. The cover can come from a frame of the existing video or from
/// the photo library; the video is never touched.
struct ClipEditSheet: View {
    let clip: Clip
    @EnvironmentObject var engine: ClipsEngine
    @Environment(\.dismiss) private var dismiss

    @State private var caption: String
    @State private var pickerItem: PhotosPickerItem?
    @State private var newCover: UIImage?
    @State private var saving = false
    @State private var errorText: String?

    init(clip: Clip) {
        self.clip = clip
        _caption = State(initialValue: clip.caption ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                    coverSection
                    captionSection
                    if let errorText {
                        Text(errorText)
                            .font(VoiidFont.caption)
                            .foregroundColor(VoiidColor.error)
                    }
                }
                .padding(VoiidSpacing.md)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Edit clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().tint(VoiidColor.primary)
                    } else {
                        Button("Save") { save() }
                            .disabled(!hasChanges)
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        newCover = image
                    }
                }
            }
        }
    }

    /// Save must be reachable only when something actually changed, so an accidental
    /// tap cannot mint a pointless PATCH (and a new cover object) for no edit at all.
    private var hasChanges: Bool {
        newCover != nil || caption != (clip.caption ?? "")
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            Text("Cover")
                .font(VoiidFont.headline)
                .foregroundColor(VoiidColor.textPrimary)

            HStack(spacing: VoiidSpacing.md) {
                Group {
                    if let newCover {
                        Image(uiImage: newCover).resizable().scaledToFill()
                    } else {
                        ClipThumbnail(url: clip.thumbURL, localPath: clip.localThumbPath)
                    }
                }
                .frame(width: 90, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md))

                VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choose image", systemImage: "photo")
                            .font(VoiidFont.subhead)
                            .foregroundColor(VoiidColor.primary)
                    }
                    if newCover != nil {
                        Button {
                            newCover = nil
                            pickerItem = nil
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                                .font(VoiidFont.subhead)
                                .foregroundColor(VoiidColor.textSecondary)
                        }
                    }
                    Text("The video itself can't be changed.")
                        .font(VoiidFont.caption)
                        .foregroundColor(VoiidColor.textSecondary)
                }
                Spacer()
            }
        }
    }

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            Text("Caption")
                .font(VoiidFont.headline)
                .foregroundColor(VoiidColor.textPrimary)
            TextField("Add a caption", text: $caption, axis: .vertical)
                .lineLimit(3...8)
                .font(VoiidFont.body)
                .foregroundColor(VoiidColor.textPrimary)
                .padding(VoiidSpacing.sm)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md))
            // Mirrors MAX_CAPTION_LEN in routes/clips.ts.
            Text("\(caption.count)/2200")
                .font(VoiidFont.caption)
                .foregroundColor(caption.count > 2200 ? VoiidColor.error : VoiidColor.textSecondary)
        }
    }

    private func save() {
        guard caption.count <= 2200 else {
            errorText = "Caption is too long."
            return
        }
        saving = true
        errorText = nil

        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        // An emptied caption is a CLEAR, not "leave it alone" — those are different
        // requests and the service models them distinctly.
        let clearing = trimmed.isEmpty && (clip.caption ?? "").isEmpty == false
        let captionArg: String? = trimmed.isEmpty ? nil : trimmed

        // JPEG at 0.8 to match the exporter's cover quality; a PNG cover would be
        // several megabytes for no visible gain.
        let coverData = newCover.flatMap { $0.jpegData(compressionQuality: 0.8) }

        Task {
            let error = await engine.updateClip(
                clip.id,
                caption: captionArg,
                clearCaption: clearing,
                newCoverJPEG: coverData
            )
            saving = false
            if let error {
                errorText = error
            } else {
                Haptics.success()
                dismiss()
            }
        }
    }
}

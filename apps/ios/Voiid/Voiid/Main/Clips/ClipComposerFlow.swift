//
//  ClipComposerFlow.swift
//  Voiid
//
//  Posting a clip — a full-screen pushed flow with a real back stack, built to the Voiid Ui
//  reference (Chat/ClipComposerScreen.swift):
//
//      [1] Record (ClipRecorderView)  ->  [2] Edit (ClipEditorScreen)  ->  [3] Post
//
//  ── BACK KEEPS YOUR WORK ────────────────────────────────────────────────────────
//  The camera controller lives HERE, not in the recorder, so the takes outlive the push to
//  the editor: going back lands on the recorder with every take still there — add another,
//  ✓ Next again — and going back from Post keeps every edit. Takes are only deleted when the
//  clip is posted (after its encode has copied them) or the flow is closed.
//
//  ── THE STEP CARRIES ITS VIDEO ──────────────────────────────────────────────────
//  Each destination is `.edit(url)` / `.post(url)`. The editor used to read the URL from a
//  @State set in the same update that pushed it, and on the first push the destination was
//  built before that state landed — so the first recording opened a BLANK editor and only
//  the second one worked. A value in the path cannot arrive late.
//
//  ── POST NEVER WAITS ────────────────────────────────────────────────────────────
//  Post hands the source and the edit to ClipsEngine and closes. The tile appears in the grid
//  at once with the chosen cover, and the encode and upload run behind it with progress and
//  Retry on the tile (ClipsEngine.post).
//

import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

enum ClipComposerStep: Hashable { case edit(URL), post(URL) }

struct ClipComposerFlow: View {
    @EnvironmentObject var engine: ClipsEngine
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @StateObject private var cam = ClipCameraController()
    @State private var path: [ClipComposerStep] = []
    @State private var edit = ClipEdit()
    @State private var openPanel: ClipEditPanel?
    /// The video being edited.
    @State private var sourceURL: URL?
    /// Files this flow made (a join of several takes, a library import) — its to delete.
    @State private var madeFiles: Set<URL> = []
    @State private var loadingPick = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack(path: $path) {
            cameraScreen
                .navigationDestination(for: ClipComposerStep.self) { step in
                    switch step {
                    case .edit(let url):
                        ClipEditorScreen(sourceURL: url, edit: $edit, openPanel: $openPanel,
                                         onBack: { path.removeLast() },
                                         onNext: { path.append(.post(url)) })
                            .navigationBarBackButtonHidden()
                    case .post(let url):
                        ClipPostView(sourceURL: url, edit: edit,
                                     onBack: { path.removeLast() },
                                     onEditCover: {
                                         openPanel = .cover
                                         path.removeLast()
                                     },
                                     onPost: { caption, comments, save, cover in
                                         post(source: url, caption: caption, commentsEnabled: comments,
                                              saveToPhotos: save, coverJPEG: cover)
                                     })
                            .navigationBarBackButtonHidden()
                    }
                }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Step 1: record

    private var cameraScreen: some View {
        ZStack {
            ClipRecorderView(
                cam: cam,
                onDone: { url, filter in
                    // The camera records CLEAN and reports which look was chosen; it becomes
                    // an edit, so the filter stays changeable and is applied once, at export.
                    Task { await accept(url: url, filter: filter) }
                },
                onGalleryPicked: { item in
                    Task { await loadPicked(item) }
                },
                onClose: close)

            if loadingPick {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    ProgressView("Preparing…").tint(.white).foregroundColor(.white)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(VoiidFont.footnote)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(VoiidSpacing.md)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                    .padding(.horizontal, VoiidSpacing.lg)
                    .onTapGesture { self.errorText = nil }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Intake

    private func loadPicked(_ item: PhotosPickerItem) async {
        loadingPick = true
        errorText = nil
        defer { loadingPick = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorText = "Couldn't read that video."
                return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("clip_src_\(UUID().uuidString).mp4")
            try data.write(to: tmp)
            madeFiles.insert(tmp)
            await accept(url: tmp)
        } catch {
            errorText = "Couldn't read that video."
        }
    }

    /// Opens the editor on a recording or an import. A library video longer than the cap is
    /// NOT refused: the editor opens on its first two minutes and the trim can move that
    /// window anywhere in it — refusing it told people to "trim it" with no way to.
    private func accept(url: URL, filter: ClipFilter = .none) async {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        guard seconds > 0 else {
            errorText = "Couldn't read that video."
            return
        }
        errorText = nil

        // The previous join or import is replaced by this one.
        if let old = sourceURL, old != url, madeFiles.contains(old) {
            try? FileManager.default.removeItem(at: old)
            madeFiles.remove(old)
        }
        if !cam.takes.contains(where: { $0.url == url }) { madeFiles.insert(url) }
        sourceURL = url

        // New footage: trim and cover start over. Text and sound carry across a re-record.
        var next = ClipEdit(trimStart: 0, trimEnd: min(seconds, ClipCaps.maxDurationSeconds), filter: filter)
        next.coverSeconds = min(1, next.trimEnd / 4)
        next.texts = edit.texts
        next.muted = edit.muted
        edit = next
        openPanel = nil
        path = [.edit(url)]
    }

    // MARK: - Post

    private func post(source: URL, caption: String, commentsEnabled: Bool, saveToPhotos: Bool,
                      coverJPEG: Data?) {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        // The engine owns the files from here, and deletes them once the encode has copied
        // what it needs.
        let cleanup = Array(Set(cam.takes.map(\.url)).union(madeFiles))
        cam.forgetTakes()
        madeFiles = []
        engine.post(source: source, edit: edit, coverJPEG: coverJPEG,
                    caption: trimmed.isEmpty ? nil : trimmed,
                    commentsEnabled: commentsEnabled, saveToPhotos: saveToPhotos,
                    cleanup: cleanup,
                    authorId: session.userId ?? "",
                    authorName: session.profile.fullName)
        dismiss()
    }

    private func close() {
        for url in madeFiles { try? FileManager.default.removeItem(at: url) }
        madeFiles = []
        dismiss()
    }
}

// MARK: - Caps

enum ClipCaps {
    /// Mirrors MAX_DURATION_MS / MAX_BYTE_SIZE in backend/api/src/routes/clips.ts.
    /// Enforced on BOTH sides — a client-only cap is not a cap.
    static let maxDurationSeconds: Double = 120
    static let maxBytes = 100 * 1024 * 1024
    /// Mirrors MAX_CAPTION_LEN.
    static let maxCaption = 2200
    /// 720p long edge. Above this the upload dominates on mobile data for no visible
    /// gain in a full-screen phone player.
    static let exportPreset = AVAssetExportPreset1280x720
}

// MARK: - Step 3: post

/// Caption, cover, settings, Post. Built to the Voiid Ui reference (Chat/ClipPostScreen.swift).
///
/// The cover sits beside the caption as the grid will show it — the grid is made entirely of
/// covers — and tapping it goes straight back to the cover picker. Clips are public and not
/// end-to-end encrypted, unlike everything else in Voiid, and the screen says so beside Post.
private struct ClipPostView: View {
    let sourceURL: URL
    let edit: ClipEdit
    var onBack: () -> Void
    var onEditCover: () -> Void
    /// Caption, comments on, save to Photos, the cover as JPEG.
    var onPost: (String, Bool, Bool, Data?) -> Void

    @State private var caption = ""
    @State private var allowComments = true
    @State private var saveToPhotos = false
    @State private var cover: UIImage?
    @State private var posting = false
    @FocusState private var captionFocused: Bool

    var body: some View {
        ZStack {
            VoiidColor.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: VoiidSpacing.lg) {
                    captionCard
                    settings
                    publicNote
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.sm)
                .padding(.bottom, 110)
            }
            .scrollDismissesKeyboard(.interactively)
            .softScrollEdge([.top, .bottom])

            if posting { postingOverlay }
        }
        .safeAreaInset(edge: .bottom) {
            if !posting {
                Button {
                    Haptics.success()
                    captionFocused = false
                    post()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane.fill").font(.system(size: 15, weight: .semibold))
                        Text("Post clip")
                    }
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Capsule().fill(VoiidColor.accent))
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.bottom, VoiidSpacing.sm)
            }
        }
        .navigationTitle("New clip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.tap()
                    onBack()
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                }
                .accessibilityLabel("Back to editing")
                .disabled(posting)
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: edit) {
            // Mirror the exporter's precedence exactly: an uploaded image wins over the
            // frame, so what the author confirms here is what the grid will show.
            if let custom = edit.customCoverJPEG {
                cover = UIImage(data: custom)
            } else {
                cover = try? await ClipExporter.frame(from: sourceURL, at: edit.coverSeconds,
                                                      filter: edit.filter)
            }
        }
    }

    // MARK: Caption + cover

    private var captionCard: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(alignment: .top, spacing: VoiidSpacing.md) {
                Button {
                    Haptics.tap()
                    onEditCover()
                } label: {
                    ZStack {
                        if let cover {
                            Image(uiImage: cover).resizable().scaledToFill()
                        } else {
                            ClipShimmer()
                        }
                    }
                    .frame(width: 96, height: 170)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        Text("Edit cover")
                            .font(VoiidFont.rounded(11, .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(.black.opacity(0.55))
                    }
                    .overlay(alignment: .topTrailing) {
                        Text(ClipEditorScreen.short(edit.duration))
                            .font(VoiidFont.rounded(10.5, .semibold))
                            .monospacedDigit()
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Capsule().fill(.black.opacity(0.55)))
                            .padding(6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Edit cover")

                VStack(alignment: .leading, spacing: 0) {
                    TextField("", text: $caption,
                              prompt: Text("Write a caption…").foregroundColor(VoiidColor.placeholder),
                              axis: .vertical)
                        .focused($captionFocused)
                        .font(VoiidFont.rounded(15))
                        .foregroundColor(VoiidColor.textPrimary)
                        .lineLimit(7, reservesSpace: true)
                        .onChange(of: caption) { _, new in
                            if new.count > ClipCaps.maxCaption { caption = String(new.prefix(ClipCaps.maxCaption)) }
                        }
                    Spacer(minLength: 0)
                    Text("\(caption.count)/\(ClipCaps.maxCaption)")
                        .font(VoiidFont.rounded(11))
                        .monospacedDigit()
                        .foregroundColor(VoiidColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: 170)
            }

            HStack(spacing: 8) {
                insertChip("number", "Hashtag", insert: "#")
                insertChip("at", "Mention", insert: "@")
                Spacer()
            }
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func insertChip(_ icon: String, _ label: String, insert: String) -> some View {
        Button {
            Haptics.tap()
            let needsSpace = !(caption.isEmpty || caption.hasSuffix(" ") || caption.hasSuffix("\n"))
            caption += (needsSpace ? " " : "") + insert
            captionFocused = true
        } label: {
            Label(label, systemImage: icon)
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(VoiidColor.textPrimary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Settings

    private var settings: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                rowIcon("globe")
                Text("Who can watch")
                    .font(VoiidFont.rounded(15, .medium))
                    .foregroundColor(VoiidColor.textPrimary)
                Spacer()
                Text("Everyone")
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .frame(minHeight: 56)
            divider
            toggleRow("bubble.right", "Allow comments",
                      note: "People can comment and reply.", isOn: $allowComments)
            divider
            toggleRow("square.and.arrow.down", "Save to Photos",
                      note: "Keeps a copy of the finished clip on this phone.", isOn: $saveToPhotos)
        }
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(VoiidColor.textPrimary.opacity(0.07)).frame(height: 1).padding(.leading, 56)
    }

    private func toggleRow(_ icon: String, _ title: String, note: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            rowIcon(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(VoiidFont.rounded(15, .medium))
                    .foregroundColor(VoiidColor.textPrimary)
                Text(note)
                    .font(VoiidFont.rounded(12))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(VoiidColor.accent)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    private func rowIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(VoiidColor.accent)
            .frame(width: 28, height: 28)
    }

    private var publicNote: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
            Text("Clips are public. Unlike your chats and moments, they aren't end-to-end encrypted.")
                .font(VoiidFont.rounded(12))
        }
        .foregroundColor(VoiidColor.textSecondary)
        .padding(.horizontal, VoiidSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Posting

    /// A beat on the cover with a tick, then the flow closes. The encode and upload carry on
    /// in the grid, on the clip's tile — nothing here waits on them.
    private var postingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Group {
                        if let cover {
                            Image(uiImage: cover).resizable().scaledToFill()
                        } else {
                            Color.black
                        }
                    }
                    .frame(width: 120, height: 212)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.35)))
                    Image(systemName: "checkmark")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(VoiidColor.success))
                        .transition(.scale.combined(with: .opacity))
                }
                Text("Posting your clip")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(.white)
                Text("It's uploading in Clips — you can keep using Voiid.")
                    .font(VoiidFont.rounded(13))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .transition(.opacity)
    }

    private func post() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { posting = true }
        Task { @MainActor in
            // The tile needs its cover the moment it appears, so make sure there is one.
            if cover == nil, edit.customCoverJPEG == nil {
                cover = try? await ClipExporter.frame(from: sourceURL, at: edit.coverSeconds, filter: edit.filter)
            }
            let jpeg = edit.customCoverJPEG ?? cover?.jpegData(compressionQuality: 0.8)
            try? await Task.sleep(for: .milliseconds(700))
            onPost(caption, allowComments, saveToPhotos, jpeg)
        }
    }
}

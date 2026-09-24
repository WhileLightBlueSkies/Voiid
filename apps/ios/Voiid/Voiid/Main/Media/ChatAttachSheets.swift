//
//  ChatAttachSheets.swift
//  Voiid
//
//  The chat's attach sheet, and the compressor sheet a file over 25 MB opens. Built to the
//  Voiid Ui reference (Chat/ChatAttachments.swift) over Networking/ChatMediaCompressor.swift.
//
//  ── ASK ONLY WHERE THERE IS A CHOICE ────────────────────────────────────────────
//  A photo over the limit is compressed without a word — there is no visible trade-off to
//  weigh. The sheet appears only where the person is choosing something real: how much quality
//  to keep in a video, how much of a long video to send, whether a PDF may lose selectable text.
//  A file nothing can shrink gets one plain explanation, not a disabled button.
//
//  ── THE RECOMMENDED CHOICE IS ALREADY MADE ──────────────────────────────────────
//  The best option is selected when the sheet opens, and the button says what will happen and
//  roughly how big it will be: one tap in the common case. The alternatives sit under it.
//

import AVFoundation
import PDFKit
import SwiftUI

// MARK: - Attach sheet

enum ChatAttachAction: Equatable { case photos, camera, document, location, poll }

struct ChatAttachSheet: View {
    let allowsPoll: Bool
    var onChoose: (ChatAttachAction) -> Void

    var body: some View {
        VStack(spacing: VoiidSpacing.lg) {
            HStack(alignment: .top, spacing: 0) {
                action(.photos, "photo.on.rectangle.angled", "Photos", VoiidColor.accent)
                action(.camera, "camera.fill", "Camera", Color(red: 0.94, green: 0.45, blue: 0.3))
                action(.document, "doc.fill", "Document", Color(red: 0.33, green: 0.54, blue: 0.95))
                action(.location, "location.fill", "Location", Color(red: 0.2, green: 0.68, blue: 0.44))
                if allowsPoll {
                    action(.poll, "chart.bar.fill", "Poll", Color(red: 0.93, green: 0.66, blue: 0.16))
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 11))
                Text("Files up to 25 MB. Bigger ones are compressed on this phone first, then end-to-end encrypted.")
                    .font(VoiidFont.rounded(12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(VoiidColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, VoiidSpacing.lg)
        .padding(.top, VoiidSpacing.lg + 6)
        .padding(.bottom, VoiidSpacing.md)
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private func action(_ kind: ChatAttachAction, _ icon: String, _ label: String, _ tint: Color) -> some View {
        Button {
            Haptics.tap()
            onChoose(kind)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(tint.gradient))
                Text(label)
                    .font(VoiidFont.rounded(12, .medium))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - Compress sheet

struct ChatCompressSheet: View {
    let file: ChatOversizeFile
    /// The file to send: its location, type, and document name (nil for a video).
    var onReady: (URL, String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: Equatable { case choose, working, done(Int64), failed(String) }

    @State private var phase: Phase = .choose
    @State private var progress: Double = 0
    @State private var videoChoice = "best"
    @State private var pdfChoice: ChatPDFCompressor.Quality = .balanced
    @State private var trimSeconds: Double = 0
    @State private var thumbnail: UIImage?
    @State private var work: Task<Void, Never>?

    // MARK: Derived

    private var fullSeconds: Double {
        if case .video(let s) = file.kind { return s }
        return 0
    }

    /// A video too long for even the lowest quality: it has to be trimmed as well.
    private var needsTrim: Bool {
        if case .video = file.kind {
            return ChatVideoPlanner.plans(seconds: fullSeconds, sourceBytes: file.bytes).isEmpty
        }
        return false
    }

    private var sendSeconds: Double { needsTrim ? trimSeconds : fullSeconds }

    private var videoPlans: [ChatVideoPlan] {
        guard fullSeconds > 0, sendSeconds > 0 else { return [] }
        let bytes = Int64(Double(file.bytes) * sendSeconds / fullSeconds)
        return ChatVideoPlanner.plans(seconds: sendSeconds, sourceBytes: bytes)
    }

    private var selectedPlan: ChatVideoPlan? {
        videoPlans.first { $0.id == videoChoice } ?? videoPlans.first
    }

    /// What the chosen option is expected to come out at.
    private var estimate: Int64? {
        switch file.kind {
        case .video: selectedPlan?.estimatedBytes
        case .pdf(let pages): ChatPDFCompressor.estimate(pages: pages, quality: pdfChoice)
        case .other: nil
        }
    }

    private var canCompress: Bool {
        switch file.kind {
        case .video: selectedPlan != nil
        case .pdf: true
        case .other: false
        }
    }

    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 1)
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: VoiidSpacing.md) {
                    header
                    meter
                    content
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.sm)
                .padding(.bottom, 120)
                .animation(motion, value: phase)
            }
            .softScrollEdge([.top, .bottom])
            .background(VoiidColor.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle(canCompress ? "Compress to send" : "Too big to send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(28)
        .interactiveDismissDisabled(phase == .working)
        .task {
            if needsTrim { trimSeconds = min(fullSeconds, ChatVideoPlanner.maxSeconds()) }
            thumbnail = await Self.thumbnail(for: file)
        }
        .onDisappear {
            work?.cancel()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    VoiidColor.accent.opacity(0.14)
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundColor(VoiidColor.accentInk)
                }
                if case .video = file.kind, thumbnail != nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(VoiidFont.rounded(13))
                    .foregroundColor(VoiidColor.textSecondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch file.kind {
        case .video: "play.rectangle.fill"
        case .pdf: "doc.richtext.fill"
        case .other: "doc.fill"
        }
    }

    private var detail: String {
        let size = ChatMediaLimit.text(file.bytes)
        switch file.kind {
        case .video(let s): return "\(size) · \(Self.clock(s))"
        case .pdf(let p): return "\(size) · \(p) page\(p == 1 ? "" : "s")"
        case .other: return size
        }
    }

    // MARK: Meter

    /// The limit as a line on a bar: how far over the file is, and where the choice lands.
    private var meter: some View {
        let result: Int64? = { if case .done(let b) = phase { return b }; return estimate }()
        let span = Double(max(file.bytes, ChatMediaLimit.bytes)) * 1.04
        return VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                let w = geo.size.width
                let limitX = w * Double(ChatMediaLimit.bytes) / span
                ZStack(alignment: .leading) {
                    Capsule().fill(VoiidColor.fieldFill)
                    Capsule().fill(Color.orange.opacity(0.4))
                        .frame(width: w * Double(file.bytes) / span)
                    if let result {
                        Capsule().fill(VoiidColor.accent)
                            .frame(width: max(10, w * Double(result) / span))
                    }
                    Capsule().fill(VoiidColor.textPrimary)
                        .frame(width: 2, height: 20)
                        .offset(x: limitX - 1)
                }
                .frame(height: 10)
                .overlay(alignment: .topLeading) {
                    Text("25 MB")
                        .font(VoiidFont.rounded(10.5, .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .fixedSize()
                        .offset(x: min(max(0, limitX - 17), w - 36), y: -19)
                }
            }
            .frame(height: 10)
            .padding(.top, 20)
            .animation(motion, value: result)

            HStack(spacing: 14) {
                legend(Color.orange, ChatMediaLimit.text(file.bytes))
                if let result {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(VoiidColor.textSecondary)
                    legend(VoiidColor.accent, (phase == .choose ? "about " : "") + ChatMediaLimit.text(result))
                        .contentTransition(.numericText())
                }
                Spacer()
            }
        }
        .padding(14)
        .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(estimate.map { "\(ChatMediaLimit.text(file.bytes)), about \(ChatMediaLimit.text($0)) after compressing. The limit is 25 MB." }
                            ?? "\(ChatMediaLimit.text(file.bytes)). The limit is 25 MB.")
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(VoiidFont.rounded(13, .semibold))
                .monospacedDigit()
                .foregroundColor(VoiidColor.textPrimary)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .choose:
            chooser.transition(.opacity)
        case .working:
            working.transition(.opacity)
        case .done:
            done.transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        case .failed(let message):
            VStack(spacing: VoiidSpacing.md) {
                notice("exclamationmark.triangle.fill", .orange, "Couldn't compress it", message)
                chooser
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var chooser: some View {
        switch file.kind {
        case .video:
            if needsTrim { trimCard }
            section(needsTrim ? "Then choose the quality" : "Choose the quality") {
                ForEach(videoPlans) { plan in
                    option(plan.title, plan.note, plan.estimatedBytes, selected: selectedPlan?.id == plan.id) {
                        videoChoice = plan.id
                    }
                }
            }
        case .pdf(let pages):
            section("Choose the quality") {
                ForEach(ChatPDFCompressor.Quality.allCases) { q in
                    option(q.title, q.note, ChatPDFCompressor.estimate(pages: pages, quality: q),
                           selected: pdfChoice == q) { pdfChoice = q }
                }
            }
            note("Pages are saved as images, so text in the PDF can't be selected or searched afterwards.")
        case .other:
            notice("archivebox.fill", VoiidColor.textSecondary, "This file can't be made smaller",
                   "It's already compressed, so shrinking it would save almost nothing. Send the parts that are needed, or split it into files under 25 MB.")
        }
        note("Compressed on this phone, then end-to-end encrypted. The original stays as it is.")
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundColor(VoiidColor.textSecondary)
                .padding(.horizontal, 4)
            VStack(spacing: 8) { rows() }
        }
        .padding(.top, 4)
    }

    private func option(_ title: String, _ note: String, _ bytes: Int64, selected: Bool,
                        action: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            Haptics.selection()
            withAnimation(motion) { action() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? VoiidColor.accent : VoiidColor.textSecondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    Text(note)
                        .font(VoiidFont.rounded(12.5))
                        .foregroundColor(VoiidColor.textSecondary)
                }
                Spacer(minLength: 8)
                Text("about \(ChatMediaLimit.text(bytes))")
                    .font(VoiidFont.rounded(13, .semibold))
                    .monospacedDigit()
                    .foregroundColor(selected ? VoiidColor.accentInk : VoiidColor.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? VoiidColor.accent : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Too long for any quality: choose how much from the start to send.
    private var trimCard: some View {
        let maxFit = min(fullSeconds, ChatVideoPlanner.maxSeconds())
        return VStack(alignment: .leading, spacing: 10) {
            Label("Too long to send whole", systemImage: "scissors")
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
            Text("Even at the lowest quality, \(Self.clock(fullSeconds)) of video is over 25 MB. Send the first part of it.")
                .font(VoiidFont.rounded(12.5))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                Text("First \(Self.clock(trimSeconds))")
                    .font(VoiidFont.rounded(15, .semibold))
                    .monospacedDigit()
                    .foregroundColor(VoiidColor.textPrimary)
                    .contentTransition(.numericText())
                Spacer()
                Text("up to \(Self.clock(maxFit))")
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            Slider(value: $trimSeconds, in: min(10, maxFit)...maxFit, step: 1)
                .tint(VoiidColor.accent)
                .accessibilityLabel("Length to send")
                .accessibilityValue(Self.clock(trimSeconds))
        }
        .padding(14)
        .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func notice(_ icon: String, _ tint: Color, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
                .symbolRenderingMode(.multicolor)
            Text(body)
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(VoiidFont.rounded(12))
            .foregroundColor(VoiidColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Working and done

    private var working: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(VoiidColor.fieldFill, lineWidth: 7)
                Circle().trim(from: 0, to: progress)
                    .stroke(VoiidColor.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
                Text("\(Int(progress * 100))%")
                    .font(VoiidFont.rounded(22, .bold))
                    .monospacedDigit()
                    .foregroundColor(VoiidColor.textPrimary)
                    .contentTransition(.numericText())
            }
            .frame(width: 104, height: 104)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Compressing")
            .accessibilityValue("\(Int(progress * 100)) percent")

            Text("Compressing on this phone")
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
            Text("Keep Voiid open until it's done.")
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var done: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.white, VoiidColor.success)
                .symbolEffect(.bounce, options: .nonRepeating, isActive: !reduceMotion)
            if case .done(let bytes) = phase {
                Text("\(ChatMediaLimit.text(file.bytes)) → \(ChatMediaLimit.text(bytes))")
                    .font(VoiidFont.rounded(17, .bold))
                    .monospacedDigit()
                    .foregroundColor(VoiidColor.textPrimary)
            }
            Text("Sending…")
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        Group {
            switch phase {
            case .choose, .failed:
                if canCompress {
                    primary(estimate.map { "Compress and send · about \(ChatMediaLimit.text($0))" }
                            ?? "Compress and send") { start() }
                } else {
                    primary("OK") { cancel() }
                }
            case .working:
                Button {
                    Haptics.tap()
                    work?.cancel()
                    withAnimation(motion) { phase = .choose; progress = 0 }
                } label: {
                    Text("Stop")
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Capsule().fill(VoiidColor.fieldFill))
                }
                .buttonStyle(PressableButtonStyle())
            case .done:
                EmptyView()
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.bottom, VoiidSpacing.sm)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(VoiidFont.rounded(16, .semibold))
                .foregroundColor(VoiidColor.textOnAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Capsule().fill(VoiidColor.accent))
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: Work

    private func start() {
        Haptics.tap()
        progress = 0
        withAnimation(motion) { phase = .working }
        let file = file
        let plan = selectedPlan
        let quality = pdfChoice
        let seconds = sendSeconds
        work = Task { @MainActor in
            do {
                let report: @Sendable (Double) -> Void = { value in
                    Task { @MainActor in progress = max(progress, value) }
                }
                let out: URL
                let mime: String
                var documentName: String?
                switch file.kind {
                case .video:
                    guard let plan else { return }
                    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
                    out = try await ChatVideoCompressor.compress(file.url, plan: plan, range: range, progress: report)
                    mime = "video/mp4"
                case .pdf:
                    out = try await ChatPDFCompressor.compress(file.url, quality: quality, progress: report)
                    mime = "application/pdf"
                    documentName = file.name
                case .other:
                    return
                }
                try Task.checkCancellation()
                let size = ChatMediaLimit.size(of: out)
                Haptics.success()
                withAnimation(motion) {
                    progress = 1
                    phase = .done(size)
                }
                // A beat on the result, so the size it came to is seen, then it goes.
                try await Task.sleep(for: .milliseconds(900))
                onReady(out, mime, documentName)
                dismiss()
            } catch is CancellationError {
                // Stopped by the person; the chooser is already back.
            } catch {
                Haptics.error()
                withAnimation(motion) { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func cancel() {
        work?.cancel()
        dismiss()
    }

    // MARK: Helpers

    private static func thumbnail(for file: ChatOversizeFile) async -> UIImage? {
        switch file.kind {
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            else { return nil }
            return UIImage(cgImage: image)
        case .pdf:
            return PDFDocument(url: file.url)?.page(at: 0)?.thumbnail(of: CGSize(width: 180, height: 180), for: .mediaBox)
        case .other:
            return nil
        }
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

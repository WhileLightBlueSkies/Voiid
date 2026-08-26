//
//  ClipTile.swift
//  Voiid
//
//  The Clips grid tile, built to the Voiid Ui reference spec (Chat/ClipsScreen.swift).
//
//  The reference shape, verbatim, and every number here comes from it:
//    - a CARD, not a bare thumbnail: surfaceCard ground, 14pt continuous radius, hairline
//      divider stroke
//    - 0.72 aspect on the frame (not 9:16 — the card is taller than the video because the
//      handle row sits under it)
//    - the handle row BELOW the frame, not overlaid. The reference note gives the reason:
//      "at this tile size a second overlay row would leave no picture visible."
//    - views left / duration right, over a top→bottom scrim that is part of the metadata
//      row rather than a full-height wash
//
//  Two things differ from the reference, both because the reference is a static mockup
//  over `Clip.samples` and this renders real rows:
//    1. `thumbnail` resolves a real presigned URL through ClipThumbnail (shimmer, expiry,
//       404 handling) and falls back to the reference's seeded gradient when a row has no
//       cover yet — a brand-new clip has no thumb until the ladder finishes.
//    2. The avatar prefers the creator's real photo and falls back to AvatarPalette
//       initials, which is what ChatAvatar does in the reference.
//
//  Upload states (`uploading`/`failed`) are ours: the reference has no upload, and a tile
//  that cannot show a failed export would lose the user a video they waited on.
//

import SwiftUI

struct ClipTile: View {

    let clip: Clip

    /// Opening the clip and opening its creator are different intentions, so they are
    /// different targets — the reference splits them the same way.
    var onOpen: () -> Void = {}
    var onCreator: () -> Void = {}

    /// Retry/dismiss for a failed upload. Nil on surfaces that never show own-upload state.
    var onRetry: (() -> Void)?
    var onDismissFailed: (() -> Void)?
    var canRetry: Bool = false

    /// The creator handle when the row carries one, prefixed so it reads as a handle.
    ///
    /// The fallback is the display name WITHOUT an `@`: rendering "Nehal Shah" as
    /// "@Nehal Shah" would present a display name as a handle that could never be
    /// resolved — handles are lowercase, 3–20, no spaces (029_creator_profiles). The
    /// prefix is the signal for which of the two this is.
    private var handleText: String {
        if let h = clip.authorHandle, !h.isEmpty { return "@\(h)" }
        return clip.authorName
    }

    /// Identity for the avatar's colour + initials. Always the handle when there is one, so
    /// a creator's tile looks the same everywhere it appears.
    private var avatarSeed: String { clip.authorHandle ?? clip.authorName }

    /// The creator page only exists for a real handle — the fallback name cannot be routed.
    private var canOpenCreator: Bool { !(clip.authorHandle ?? "").isEmpty }

    var body: some View {
        Button {
            Haptics.tap()
            onOpen()
        } label: {
            VStack(spacing: 0) {
                frame
                handleRow
            }
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(VoiidColor.divider, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ClipTilePressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Frame

    private var frame: some View {
        ZStack(alignment: .bottom) {
            // The card is a FIXED shape and the media fits inside it, whatever its own
            // dimensions are. `Color.clear` is what holds that shape: it takes the cell's
            // width, the aspectRatio below gives it a definite height, and the media rides
            // in an overlay — so an image can never contribute its size to the layout.
            //
            // Handing the media straight to the ZStack instead (as this did) lets a
            // `scaledToFill` image report its OVERFLOWED size as the layer's size, which
            // grows the stack and changes the card's shape per clip. That is the same
            // unbounded-fill bug the story viewer's backdrop hit.
            Color.clear
                .overlay { thumbnail }
                .clipped()

            switch clip.uploadState {
            case .uploading(let progress): uploadOverlay(progress)
            case .failed(let message):     failedOverlay(message)
            case .none:                    metaRow
            }
        }
        // Aspect on the CELL, never on the image: `scaledToFill` reports an unbounded
        // ideal height, so constraining only the image makes the tile depend on its
        // container handing down a definite size — which a VStack does not.
        .aspectRatio(0.72, contentMode: .fit)
        .clipShape(
            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: 14,
                                   style: .continuous)
        )
    }

    /// The real cover when there is one; the reference's seeded gradient when there is not.
    /// Seeded from the clip id so a coverless row looks the same on every launch instead of
    /// flickering a new colour each time the grid rebuilds.
    @ViewBuilder
    private var thumbnail: some View {
        if clip.thumbURL != nil || clip.localThumbPath != nil {
            // No `.scaledToFill()` here: ClipThumbnail applies it internally, and stacking a
            // second one is what makes the fill unbounded.
            ClipThumbnail(url: clip.thumbURL, localPath: clip.localThumbPath)
        } else {
            LinearGradient(
                colors: [
                    AvatarPalette.color(for: clip.id),
                    AvatarPalette.color(for: avatarSeed).opacity(0.7),
                    .black.opacity(0.6),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }

    /// Views left, runtime right — the two facts you scan a grid for. The scrim is padded
    /// into this row rather than washing the whole frame, so the picture stays visible.
    private var metaRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill").font(.system(size: 9))
            Text(ClipCount.compact(clip.viewCount))
                .font(VoiidFont.rounded(11, .semibold))

            Spacer(minLength: 4)

            // Hidden rather than faked when a row predates the duration column.
            if let text = ClipDuration.label(clip.durationMs) {
                Text(text)
                    .font(VoiidFont.rounded(11, .semibold))
                    .monospacedDigit()
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 7)
        .padding(.bottom, 6)
        .padding(.top, 18)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Handle row

    @ViewBuilder
    private var handleRow: some View {
        // Not a Button when there is no creator page to open: a row that highlights and
        // then does nothing is worse than a row that never offered.
        if canOpenCreator {
            Button {
                Haptics.tap()
                onCreator()
            } label: { handleRowLabel }
            .buttonStyle(.plain)
        } else {
            handleRowLabel
        }
    }

    private var handleRowLabel: some View {
        Group {
            HStack(spacing: 4) {
                avatar.frame(width: 18, height: 18).clipShape(Circle())

                Text(handleText)
                    .font(VoiidFont.rounded(10.5))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if clip.authorVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 9))
                        .foregroundColor(VoiidColor.accent)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = clip.authorPhotoURL {
            ClipThumbnail(url: url)
        } else {
            // The reference's ChatAvatar, inline: same palette, same initials, same
            // size-relative type scale.
            Circle()
                .fill(
                    LinearGradient(colors: [AvatarPalette.color(for: avatarSeed),
                                            AvatarPalette.color(for: avatarSeed).opacity(0.72)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay {
                    Text(AvatarPalette.initials(for: avatarSeed))
                        .font(.system(size: 18 * 0.38, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }
        }
    }

    // MARK: - Upload states

    private func uploadOverlay(_ progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(VoiidColor.primary)
                    .frame(width: 56)
                Text("Uploading")
                    .font(VoiidFont.rounded(10, .medium))
                    .foregroundColor(.white)
            }
        }
    }

    /// THE ONE TILE WHERE A MIS-TAP COSTS THE USER A VIDEO. Retry and Dismiss sit
    /// millimetres apart inside a third of a phone width, and Dismiss discards an export
    /// the user already waited through — so both get a real ≥44pt target, Retry comes
    /// first, and only Retry carries a visible capsule so the two never read alike.
    private func failedOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16)).foregroundColor(VoiidColor.error)
                Text("Upload failed")
                    .font(VoiidFont.rounded(10, .semibold)).foregroundColor(.white)

                if canRetry, let onRetry {
                    Button {
                        Haptics.tap()
                        onRetry()
                    } label: {
                        Text("Retry")
                            .font(VoiidFont.rounded(12, .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, VoiidSpacing.md)
                            .frame(height: 30)
                            .background(Capsule().fill(VoiidColor.fieldFill))
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftPressStyle())
                }

                if let onDismissFailed {
                    Button {
                        Haptics.tap()
                        onDismissFailed()
                    } label: {
                        Text("Dismiss")
                            .font(VoiidFont.rounded(12, .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
            .padding(.horizontal, VoiidSpacing.xs)
        }
        .accessibilityLabel("Upload failed. \(message)")
    }

    private var accessibilityText: String {
        var parts = [handleText, "\(ClipCount.compact(clip.viewCount)) views"]
        if let d = ClipDuration.label(clip.durationMs) { parts.append(d) }
        return parts.joined(separator: ", ")
    }
}

/// Tiles dip a little less than buttons: they are large, and the same ratio on a bigger
/// element reads as a bigger movement.
struct ClipTilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

//
//  StoryMomentCard.swift
//  Voiid
//
//  The Moments card — one tile per AUTHOR CONTEXT, never one per story, matching the
//  ordering rule StoriesHomeView has always followed (§8.3).
//
//  ── WHY A CARD AND NOT THE OLD ROW ──────────────────────────────────────────────
//  The reference design (Voiid Ui / MemoriesScreen) carries its content on a gradient
//  card with the progress pips laid across the top edge. That treatment is adopted here
//  because a story IS a picture — an avatar-and-two-lines row showed a name where the
//  media should be. What is NOT adopted is the reference's data: it renders a permanent
//  titled collection ("Goa Trip 🏝️") with an absolute date. A Voiid story has no title
//  (only an E2EE caption the server never sees) and expires in 24h, so this card carries
//  a display name and a RELATIVE age instead. See StoriesHomeView for the full list.
//
//  ── THE TILE IS PORTRAIT, AND THE RATIO IS THE WHOLE POINT ──────────────────────
//  Stories are shot on a phone held upright: the media is 9:16. The tile used to be given
//  a hardcoded `height: 208` against a column that measures ~175pt on a 393pt iPhone —
//  a 0.84 ratio, near-square. `scaledToFill` then had to crop away the top and bottom of
//  every frame to fit it, so each tile showed a narrow horizontal band sliced out of the
//  middle of something composed vertically. Heads left the frame. That is what read as
//  "doesn't look good", and no amount of scrim or type work fixes it — the crop is the bug.
//
//  So the card now takes an `aspect` (portrait 3:4) and derives its height from its OWN
//  measured width. Two consequences worth stating:
//
//    WHY DERIVED, NOT FIXED — one hardcoded height cannot be correct on both a 320pt-wide
//    SE column and a 430pt Pro Max column; it would be near-square on one and a letterbox
//    on the other. Width is the dimension the grid actually decides, so height is the one
//    that must follow it. Nothing here needs to know the screen width or the column count.
//
//    WHY 3:4 AND NOT A FULL 9:16 — 9:16 at a ~175pt column is 311pt tall, so a single row
//    plus the banner would overflow a 667pt SE before the user has seen one full tile, and
//    a grid of them reads as a wall of slivers. 3:4 is the portrait ratio Photos and every
//    phone photo grid settle on: it keeps the frame's vertical composition (a subject stays
//    a subject) while staying a browsable tile. The remaining crop is symmetric top/bottom
//    around the centre, which is where phone-shot subjects sit.
//
//  The old comment here warned that `.aspectRatio(.fit)` collapses a fixed-width child
//  inside an HStack to a stub. That was true, and it was about a HORIZONTAL RAIL that no
//  longer exists — this card has exactly one call site now, the grid. In a LazyVGrid the
//  column hands the child a definite width and leaves height free, which is the opposite
//  situation, so the ratio is resolved from the measured width instead (below). The rail's
//  `width`/`compact` parameters are gone with the rail; re-adding a rail means solving the
//  rail's own layout, not reviving a flag this file no longer has a use for.
//
//  ── THE THUMBNAIL IS REAL, OR IT IS A GRADIENT ──────────────────────────────────
//  The reference draws a gradient keyed to the item id because it has no files. We do
//  have files — but only for stories already downloaded and decrypted to disk
//  (`localPath`, set by StoryEngine.ensureDownloaded). So: if the plaintext is on disk we
//  draw the real frame; otherwise we fall back to the id-keyed gradient. We NEVER kick off
//  a download from here. Auto-download is throttled deliberately in the engine
//  (`autoDownloadEligible`), and a grid that fetched every tile's blob on appear would
//  quietly defeat that throttle and pull the whole feed's media on every launch.
//

import SwiftUI

struct StoryMomentCard: View {
    let context: StoryContext

    /// Height ÷ width. Portrait by default — see the ratio note above. Injected rather than
    /// baked in so a future caller (a rail, a wider iPad column) can pick its own without
    /// this file growing a mode flag again.
    var aspect: CGFloat = 4.0 / 3.0

    let action: () -> Void

    @State private var frame: UIImage?

    private var authorName: String { UserDirectory.shared.displayName(context.authorId) }

    /// The story whose frame represents the context: the first one the viewer will actually
    /// open, so the tile shows what tapping it plays. Not `newest` — the viewer resumes at
    /// `firstUnviewedIndex`, and a cover that showed a different frame than the one that
    /// starts playing reads as a bug.
    private var coverStory: Story? {
        let i = context.firstUnviewedIndex
        return context.stories.indices.contains(i) ? context.stories[i] : context.stories.first
    }

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            // The grid column fixes the width and leaves the height free, so the tile reads
            // its own width back and sets height from it. `Color.clear` is the measuring
            // stand-in: it takes the column's width, reports it, and contributes no size of
            // its own, so the frame below is the single thing deciding the tile's height.
            Color.clear
                .aspectRatio(1 / aspect, contentMode: .fit)
                .overlay { cardBody }
        }
        .buttonStyle(SoftPressStyle(scale: 0.97))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .task(id: coverStory?.localPath) { await loadFrame() }
    }

    private var cardBody: some View {
        ZStack(alignment: .bottomLeading) {
            thumbnail

            // Bottom scrim. Without it the name sits on whatever the frame happens to be
            // and is unreadable on a bright one. Three stops, not two: a linear ramp from
            // .clear spends most of its length too faint to do anything, so the old
            // centre-to-bottom gradient was still near-transparent where the smaller
            // secondary line sits. This holds ~0 over the top half (the picture stays the
            // picture), then ramps hard through the lower third. 0.92 at the very bottom
            // clears 4.5:1 for white against a blown-out white frame, which is the worst
            // case this has to survive — see §12 on legibility over arbitrary media.
            LinearGradient(
                stops: [
                    .init(color: .clear,             location: 0.42),
                    .init(color: .black.opacity(0.34), location: 0.70),
                    .init(color: .black.opacity(0.92), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(authorName)
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)                 // two lines, because a name is not truncatable
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)

                // RELATIVE, never "Aug 9, 2024". The card is showing something that dies
                // in under a day; how long it has left is the only reading of time that
                // means anything here.
                Text(StoryTime.relative(context.newest?.createdAt))
                    .font(VoiidFont.rounded(11, .regular))
                    // 0.78 white on the scrim was the weakest text on the screen. 0.86 keeps
                    // it clearly secondary to the name while staying legible on a bright frame.
                    .foregroundColor(.white.opacity(0.86))
                    .lineLimit(1)
            }
            // A soft shadow under both lines. The scrim handles the average case; this covers
            // the one it cannot — a small bright specular highlight sitting directly behind a
            // letter, where a uniform scrim is still locally out-contrasted.
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .top) { pips }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                // The unviewed accent is carried on the card's own edge, which is what
                // replaces the ring the old avatar row drew. Viewed falls back to the
                // divider so the two are still distinguishable without colour alone —
                // the pips carry the same fact a second time, in fill rather than hue.
                .strokeBorder(context.hasUnviewed ? VoiidColor.accent : VoiidColor.divider,
                              lineWidth: context.hasUnviewed ? 2.5 : 1)
        }
        // Teal #13828C is mid-luminance, so it can sink into media of a similar tone from
        // either direction. A hairline of near-black just inside the stroke separates it
        // from a light frame, and the ring's own saturation carries it against a dark one.
        // strokeBorder (not stroke) keeps both lines fully inside the clip — a centred
        // stroke would lose its outer half to the corner radius.
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .inset(by: context.hasUnviewed ? 2.5 : 1)
                .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Pips
    //
    // REAL, not decorative. `count` is how many unexpired stories this author actually has
    // in the local store, and `currentIndex` is `firstUnviewedIndex` — the same value the
    // viewer opens on — so a filled pip means "you have seen this one". A fully-viewed
    // context therefore shows every pip filled, because firstUnviewedIndex returns 0 only
    // when something is unseen; the `allViewed` branch below covers the other case.
    //
    // The pips sit on raw media at the top of the tile, where there is no scrim — an unfilled
    // pip is white at 0.35 and simply vanished against a bright sky. They get their own short
    // top scrim, mirroring the bottom one, so both the filled and unfilled states are readable
    // over any frame. Without it the count silently under-reports on exactly the photos people
    // take outdoors.

    private var pips: some View {
        StorySegmentProgressView(count: context.stories.count,
                                 currentIndex: context.hasUnviewed ? context.firstUnviewedIndex
                                                                   : context.stories.count,
                                 progress: 0)
            .padding(.horizontal, 9)
            .padding(.top, 9)
            .padding(.bottom, 14)
            .background(
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .bottom)
            )
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        if let frame {
            // `.fill` still crops — but now it crops a 9:16 frame to 3:4 rather than to a
            // square, which is a trim off the top and bottom instead of an excision of most
            // of the picture. clipped() keeps the overflow from painting over neighbours
            // before the rounded clip applies.
            Image(uiImage: frame)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            // The stand-in, keyed off the author id so a given person's tile is the same
            // colour on every launch. `hashValue` is never used for this — Swift seeds it
            // per process, so the colour would change every launch (cf. AvatarPalette).
            LinearGradient(
                colors: [
                    AvatarPalette.color(for: context.authorId),
                    AvatarPalette.color(for: context.authorId + "b").opacity(0.7),
                    .black.opacity(0.65),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay(alignment: .center) {
                // Only meaningful before any frame is on disk: it says "there is media here
                // and it has not been fetched yet", which is true of every undownloaded tile.
                // Nudged up by the height of the name block so it reads as centred in the
                // visible picture area rather than centred behind the scrim.
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.white.opacity(0.38))
                    .padding(.bottom, 22)
            }
        }
    }

    /// Reads ONLY what is already decrypted on disk. `backdrop(at:isVideo:)` is used rather
    /// than `image(at:)` because it is the one path that handles a video (first frame) as
    /// well as a photo, and it is already the cheap cached decode the viewer uses.
    private func loadFrame() async {
        guard let story = coverStory,
              let path = story.localPath,
              FileManager.default.fileExists(atPath: path) else { frame = nil; return }
        let isVideo = story.media.mime.hasPrefix("video")
        frame = await StoryImageCache.shared.backdrop(at: URL(fileURLWithPath: path), isVideo: isVideo)
    }

    private var accessibilityText: String {
        let n = context.stories.count
        let updates = n == 1 ? "1 update" : "\(n) updates"
        let state = context.hasUnviewed ? "unseen" : "seen"
        return "\(authorName), \(updates), \(StoryTime.relative(context.newest?.createdAt)), \(state)"
    }
}

// MARK: - Relative time

/// Shared by the card and the header so a story's age is phrased identically in both.
///
/// Deliberately relative-only. A 24-hour object has no useful calendar date: "Aug 9" tells
/// you nothing you did not already know, while "2h ago" tells you roughly how long is left.
enum StoryTime {
    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

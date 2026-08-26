//
//  StoryQuoteView.swift
//  Voiid
//
//  The quoted-moment header on a story-reply bubble in the chat.
//
//  WHY THIS EXISTS. A reply sent from the Moments viewer travels as a StoryReplyEnvelope
//  carrying storyId / storyAuthorId / storyCreatedAt alongside the body — the WhatsApp model,
//  where the reply lands in the ordinary 1:1 chat and outlives the story. ChatEngine decoded
//  all of that and then returned `reply.reaction ?? reply.text ?? ""`, discarding every field
//  except the body, so a tapped "❤️" arrived in the recipient's chat as a lone emoji with
//  nothing whatsoever saying which moment it answered. This view is the missing half.
//
//  WHY IT LOOKS LIKE THE MESSAGE QUOTE. ChatDetailView already renders a quoted-reply header
//  (accent rail + author line in the accent + a two-line secondary body, on a translucent
//  scrim inside the bubble). A story quote is the SAME idea about a different object, so it
//  reuses that construction verbatim and adds only the one thing a moment has that a message
//  does not: a thumbnail. The caller passes the bubble-aware colours down (`bubbleAccent`,
//  `bubbleTextSecondary`, and the fill), because a quote on YOUR filled-teal bubble has to
//  invert and the tokens do not know which bubble they are on.
//
//  WHY NOTHING IS SNAPSHOTTED. A story is a 24-hour E2EE object. Copying its media (or even a
//  caption) into the message store would either rot, or duplicate plaintext of something the
//  author can delete, and the reply itself is permanent — it must still render honestly a week
//  later. So only the ID travels, and the media is resolved from StoryStore at RENDER time:
//  present while the blob is still on disk, an explicit "Moment expired" once it is not.
//
//  WHY IT NEVER DOWNLOADS. `StoryEngine.ensureDownloaded` is throttled deliberately, and a
//  chat scrolling past twenty story replies must not fire twenty fetches for media the user
//  did not ask to see. This view only ever reads a file that is ALREADY on disk (the exact
//  same `story.localPath` + `StoryImageCache.backdrop` path `StoryMomentCard.loadFrame` uses),
//  so it is cheap and it can never resurrect an expired story.
//

import SwiftUI

struct StoryQuoteView: View {
    let storyId: String
    let authorId: String?
    /// The MOMENT's creation time, not the reply's — "your moment · 3h ago" is about the thing
    /// being quoted, and the bubble's own timestamp already reports when the reply was sent.
    let createdAt: Date?
    /// Bubble-aware colours, resolved by the caller (see ChatDetailView's bubbleAccent /
    /// bubbleTextSecondary): on the filled-teal sent bubble these are inverted white tones.
    let accent: Color
    let secondary: Color
    let fill: Color

    /// Three genuinely distinct states, never collapsed into two. `.loading` is the brief
    /// window while the thumbnail decodes off the main thread; `.expired` is the honest,
    /// permanent end state of a 24h object; `.present` is a real frame. Collapsing loading
    /// into expired would flash "Moment expired" at every story that is actually still there,
    /// and collapsing expired into loading would spin forever on one that is genuinely gone.
    private enum Frame: Equatable {
        case loading
        case present(UIImage)
        case expired
    }

    @State private var frame: Frame = .loading
    /// Dynamic Type: past the accessibility sizes the 44pt thumbnail and the two text lines
    /// stop fitting side by side inside an already-inset bubble, so the thumbnail is dropped
    /// and the text takes the full width. The words carry the meaning; the picture is the
    /// garnish, and a garnish that squeezes the label to three characters is worse than none.
    @Environment(\.sizeCategory) private var sizeCategory
    private var isAccessibilitySize: Bool { sizeCategory.isAccessibilityCategory }

    /// Square, and the same 44pt the rest of the app uses as its smallest meaningful block —
    /// large enough to recognise a face in, small enough that the quote stays a header rather
    /// than becoming the message.
    private let thumbSide: CGFloat = 44

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3)

            if !isAccessibilitySize { thumbnail }

            VStack(alignment: .leading, spacing: 1) {
                Text(authorLine)
                    .font(VoiidFont.rounded(11, .semibold))
                    .foregroundColor(accent)
                    .lineLimit(1)
                Text(bodyLine)
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundColor(secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // The rail, the thumbnail and the two lines are ONE idea; read as four fragments they
        // are noise. Combined, VoiceOver says "Reply to Ada's moment, 3h ago" once.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        // Keyed on the id so a recycled bubble in a scrolling list re-resolves rather than
        // showing the previous row's frame.
        .task(id: storyId) { await resolve() }
    }

    // MARK: - Pieces

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            // A neutral tile under every state, so loading → present is a fill swapping for a
            // picture rather than a hole in the layout opening and closing. This is also what
            // keeps an expired quote from reading as "broken image".
            RoundedRectangle(cornerRadius: 6).fill(secondary.opacity(0.18))

            switch frame {
            case .loading:
                // Nothing but the tile. A spinner here would be four pixels of animation per
                // bubble in a scrolling list, drawing the eye to the least important thing on
                // screen for the ~30ms a 96px decode takes.
                EmptyView()
            case .present(let img):
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            case .expired:
                // The honest marker. Never a placeholder photo, never a guessed caption — the
                // media is genuinely gone and the interface says so instead of implying it is
                // still loading.
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(secondary)
            }
        }
        .frame(width: thumbSide, height: thumbSide)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var authorLine: String {
        guard let authorId else { return "Moment" }
        if authorId == TokenStore.shared.userId { return "Your moment" }
        let name = UserDirectory.shared.displayName(authorId)
        return name.isEmpty ? "Moment" : name
    }

    /// The second line reports the MOMENT's state, which is the one thing the bubble's own
    /// metadata cannot: a reply from last week quoting a story that died six days ago must say
    /// so, not silently show an empty tile.
    private var bodyLine: String {
        switch frame {
        case .expired: return "Moment expired"
        case .loading, .present:
            let age = StoryTime.relative(createdAt)
            return age.isEmpty ? "Moment" : "Moment · \(age)"
        }
    }

    private var accessibilityLabel: String {
        "Reply to \(authorLine). \(bodyLine)."
    }

    // MARK: - Resolution

    /// Reads ONLY what is already on disk. No network, no `ensureDownloaded`, no writes to
    /// story state — a chat scrolling past a story reply must cost nothing and must never
    /// re-fetch (or re-mark) a moment. Mirrors StoryMomentCard.loadFrame exactly, so a story
    /// the tray already warmed is a cache hit here.
    private func resolve() async {
        guard let story = StoryStore.story(storyId),
              let path = story.localPath,
              FileManager.default.fileExists(atPath: path) else {
            frame = .expired
            return
        }
        let isVideo = story.media.mime.hasPrefix("video")
        let img = await StoryImageCache.shared.backdrop(at: URL(fileURLWithPath: path), isVideo: isVideo)
        // A row that exists with a path we cannot decode is, from the reader's point of view,
        // the same situation as a swept one: there is nothing to show. Saying "expired" is
        // closer to true than spinning forever on a frame that will never arrive.
        frame = img.map(Frame.present) ?? .expired
    }
}

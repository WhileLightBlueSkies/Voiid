//
//  MediaKeyResolver.swift
//  Voiid
//
//  Turns an opaque R2 OBJECT KEY into a fetchable URL, on demand, with a cache.
//
//  ── THE PROBLEM THIS EXISTS TO SOLVE ────────────────────────────────────────────
//  `POST /media/presign-upload` returns a KEY ("media/<uploader>/<uuid>"), not a URL. Reading
//  the bytes back needs a per-caller `POST /media/presign-download` round trip. Two columns
//  nonetheless hold such a key and are rendered DIRECTLY by `ClipThumbnail(url:)`, which
//  fetches whatever string it is handed:
//
//    community_posts.media_url ..... a post's photo
//    communities.avatar_r2_key ..... a community's avatar
//
//  A raw key in either renders as a broken image for everyone, the author included. That is
//  why `CommunityPostComposer` shipped with no picker and `CommunitySettingsView` with no
//  avatar row — both said so in their headers, and both pointed at this file's absence.
//
//  ── WHY A CLIENT-SIDE RESOLVER AND NOT A PUBLIC BUCKET ──────────────────────────
//  The alternative was a route returning a long-lived or public URL for community images.
//  It was rejected, on the evidence in the code rather than on taste:
//
//    1. THE BUCKET ALSO HOLDS E2EE CIPHERTEXT. `media/...` is one flat namespace shared by
//       message attachments (routes/media.ts), which are ciphertext the server must never be
//       able to hand out, and by these plaintext community images. Making the bucket public,
//       or minting non-expiring URLs against it, widens the reach of the whole namespace to
//       solve a problem in two columns of it. A presigned GET is scoped to ONE key.
//    2. A LONG-LIVED URL CANNOT BE WITHDRAWN. A community avatar or a post photo can be
//       removed by its author or by a moderator (`community_posts.removed_at`, 047). A URL
//       that never expires keeps serving the bytes after the takedown, and nothing in the
//       product can call it back. A 1-hour presign expires on its own.
//    3. THE SERVER ALREADY DOES EXACTLY THIS FOR AVATARS. `publicCard()` in
//       routes/communities.ts presigns `avatar_r2_key` into `avatar_url` before the card goes
//       on the wire. Option (a) would have been a second, differently-shaped answer to a
//       question the codebase had already answered one way.
//
//  ── WHY THE CACHE IS KEYED ON THE KEY, NOT ON THE URL ───────────────────────────
//  `presignGet` mints a URL valid for one hour (r2.ts, GET_TTL). `ClipThumbCache` caches
//  images under the URL STRING, so a freshly presigned URL for a photo already in memory is a
//  cache miss and a re-download. Caching the key -> URL mapping here, with a margin shorter
//  than the server's TTL, means a scroll back up the feed reuses one URL and therefore one
//  cached image.
//
//  ── NOT E2EE, STATED PLAINLY ────────────────────────────────────────────────────
//  Everything this file resolves is PLAINTEXT in R2 and readable by the server: a post is a
//  broadcast (047's header) and a community avatar is shown to strangers who hold no key
//  (030's). This resolver has NO decrypt step and must never grow one — message attachments
//  go through `MediaService.download`, which returns ciphertext for `ChatEngine` to open with
//  a key that never touches the server. The two paths are separate on purpose.
//

import Foundation

/// Resolves R2 object keys to short-lived presigned GET URLs, and remembers them.
@MainActor
final class MediaKeyResolver {
    static let shared = MediaKeyResolver()

    private let api = APIClient()

    /// A resolved URL and the moment it stops being trustworthy.
    private struct Entry {
        let url: String
        let expiresAt: Date
    }

    private var cache: [String: Entry] = [:]
    /// In-flight resolutions, so twenty cards asking for one key make one round trip.
    private var inFlight: [String: Task<String?, Never>] = [:]

    /// How long a resolved URL is reused for.
    ///
    /// DELIBERATELY SHORTER THAN THE SERVER'S HOUR (r2.ts `GET_TTL` = 3600). A client that
    /// cached for exactly the server's window would hand `ClipThumbnail` a URL that expires
    /// mid-download, which renders as the broken-image state with no way for the user to tell
    /// it apart from a photo that is genuinely gone. The margin is the difference.
    private static let ttl: TimeInterval = 45 * 60

    private init() {}

    /// True when `value` is an R2 object key rather than something already fetchable.
    ///
    /// The test is on the SHAPE, not on a flag from the server, because both columns are plain
    /// `text` and have carried both kinds of value over their lifetime: `communities.
    /// avatar_r2_key` is a key, `publicCard` already turns it into an https URL, and
    /// `community_posts.media_url` is named for a URL but is about to start receiving keys.
    /// Anything already absolute is passed through untouched.
    static func isObjectKey(_ value: String) -> Bool {
        !value.hasPrefix("http://") && !value.hasPrefix("https://") && value.hasPrefix("media/")
    }

    /// The cached URL for `key`, if one is still fresh. Synchronous so a view can render the
    /// image on the first frame instead of flashing a shimmer for something it already has.
    func cached(_ key: String) -> String? {
        guard let entry = cache[key], entry.expiresAt > Date() else { return nil }
        return entry.url
    }

    /// Resolve `key` to a presigned GET URL.
    ///
    /// Returns nil on failure rather than throwing: every caller is a view whose only possible
    /// response is to draw the broken-image state, and `ClipThumbnail` already has one. A
    /// thrown error would just be caught and discarded at each call site.
    func resolve(_ key: String) async -> String? {
        if let hit = cached(key) { return hit }
        if let running = inFlight[key] { return await running.value }

        let task = Task<String?, Never> { [api] in
            struct Body: Encodable { let key: String }
            struct Resp: Decodable { let download_url: String }
            do {
                let resp: Resp = try await api.request(
                    "POST", "media/presign-download", body: Body(key: key))
                return resp.download_url
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let url = await task.value
        inFlight[key] = nil

        if let url {
            cache[key] = Entry(url: url, expiresAt: Date().addingTimeInterval(Self.ttl))
        }
        return url
    }

    /// Forget a key, so the next render re-presigns it.
    ///
    /// Called after an avatar is REPLACED: the community keeps rendering from whatever the
    /// card last carried, and a stale entry for the old key would keep the previous photo on
    /// screen for up to the TTL after the host changed it.
    func invalidate(_ key: String) {
        cache[key] = nil
    }
}


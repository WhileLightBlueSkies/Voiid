//
//  GifService.swift
//  Voiid
//
//  GIF search through our own /gifs proxy (GIPHY behind it), plus the download step that turns
//  a chosen GIF into bytes for the ordinary E2EE media path.
//
//  The download is the point. Every other messenger sends a provider URL and lets each
//  recipient fetch it — which tells the provider who received what and when, and breaks the GIF
//  permanently if the provider removes it. Fetching once here and sending ciphertext costs us
//  bandwidth and buys both properties back.
//

import Foundation

@MainActor
final class GifService {
    static let shared = GifService()
    private init() {}

    private let api = APIClient()

    struct Gif: Decodable, Identifiable {
        let id: String
        /// Full-size — downloaded, encrypted, sent.
        let url: String
        /// Small looping preview for the picker grid. Never sent to anyone.
        let preview: String
        let width: Int
        let height: Int
        let description: String
    }

    private struct SearchResponse: Decodable {
        let gifs: [Gif]
        /// False when the server has no provider key, so the UI can say so instead of spinning.
        let configured: Bool
    }

    /// Search, or trending when `query` is nil.
    func search(_ query: String?) async -> (gifs: [Gif], configured: Bool) {
        do {
            let path: String
            if let q = query, !q.isEmpty {
                let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
                path = "gifs/search?q=\(encoded)"
            } else {
                path = "gifs/trending"
            }
            let res: SearchResponse = try await api.request("GET", path)
            return (res.gifs, res.configured)
        } catch {
            // A failed GIF search must never surface as an error state — the composer stays
            // usable and the grid is simply empty.
            return ([], true)
        }
    }

    /// Fetch the GIF bytes so they can be encrypted and sent as normal media.
    ///
    /// Capped at 16 MB: a GIF is decoded fully into memory to display, and providers
    /// occasionally serve multi-megabyte files that would spike a low-end phone. Anything
    /// larger is dropped rather than risking an OOM mid-send.
    ///
    /// The cap was 8 MB under Tenor. GIPHY's `original` rendition runs larger — measured
    /// across a trending sample, the median is ~1.5 MB but the tail reaches past 10 MB, so
    /// 8 MB silently dropped a small share of perfectly ordinary GIFs.
    /// `nonisolated` because it touches no state — it fetches bytes and returns them. Left on
    /// the main actor, a multi-megabyte GIF download ran its await on the main thread, which
    /// is the wrong place for it and stalls the UI for the length of the transfer.
    nonisolated func download(_ url: String) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: u)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard data.count <= 16 * 1024 * 1024 else {
                NSLog("[VOIID] gif too large (\(data.count) bytes) — skipped")
                return nil
            }
            return data
        } catch {
            NSLog("[VOIID] gif download failed: \(error)")
            return nil
        }
    }
}

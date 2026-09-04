//
//  ReportService.swift
//  Voiid
//
//  The client half of content reports. Twin of Android `ReportService.kt`.
//
//  The backend (035_reports.sql, routes/reports.ts) shipped and no iOS code had ever called
//  it — the Report button raised "Reporting isn't available yet". Android had a complete
//  ReportSheet that was reachable from nowhere. Both halves existed; the wire between them
//  did not.
//
//  ── WHAT A REPORT MAY CARRY, AND WHAT IT MAY NOT ─────────────────────────────────
//  Reporting a CLIP or a CREATOR is unremarkable: that content is already public and the
//  server can read it.
//
//  Reporting a PERSON is the delicate one, and the schema names it carefully — the target is
//  the PERSON, never a message. There is no `message_id` field here and no way to add one,
//  because "fetch the reported message" is unbuildable and must stay unbuildable: the server
//  has no key. The sheet says so on screen rather than letting a reporter assume either way.
//  Someone reporting harassment deserves to know whether a moderator can read what was said,
//  and the honest answer is no.
//

import Foundation

/// What is being reported.
///
/// `person` maps to the server's `message_sender`, and the naming difference is deliberate:
/// the wire type says "sender" because that is the relationship, but nothing about a MESSAGE
/// travels — there is no message id here and no field to put one in.
enum ReportTarget {
    case clip(id: String)
    case creator(userId: String)
    case person(userId: String)
    /// A post in a community's Home feed (community_posts.id, 047).
    ///
    /// TARGETS THE POST, NOT ITS AUTHOR, and the distinction is the server's too (053). A
    /// person is reported through `.creator` or `.person`, and those accumulate against an
    /// account; a post report is about one piece of content and resolving it removes that
    /// content. Collapsing the two would make one bad post and a pattern of abuse into the
    /// same row.
    case communityPost(postId: String)
    /// A whole community (communities.id, 030) — "this entire community is a scam", which is
    /// a different report from any one post inside it.
    case community(communityId: String)
    /// An event LISTING (community_events.id, 032/056).
    ///
    /// Targets the listing, not the host, for the same reason `.communityPost` targets the
    /// post: resolving this takes one listing off sale, while reporting a person accumulates
    /// against their account. A host reporting their own event is refused server-side — they
    /// can cancel it — and answered with the same 202 as everything else.
    case event(eventId: String)

    /// The server's `target_type` vocabulary (routes/reports.ts TARGET_TYPES).
    var type: String {
        switch self {
        case .clip: return "clip"
        case .creator: return "creator"
        case .person: return "message_sender"
        case .communityPost: return "community_post"
        case .community: return "community"
        case .event: return "event"
        }
    }

    var id: String {
        switch self {
        case .clip(let id): return id
        case .creator(let userId): return userId
        case .person(let userId): return userId
        case .communityPost(let postId): return postId
        case .community(let communityId): return communityId
        case .event(let eventId): return eventId
        }
    }
}

/// The reasons the server accepts, in the order the sheet shows them.
///
/// Data rather than a switch so the client cannot drift into offering a reason the server
/// rejects — REASONS in routes/reports.ts is the authority and this mirrors it exactly.
enum ReportReason: String, CaseIterable, Identifiable {
    case spam
    case harassment
    case hate
    case violence
    case nudity
    case self_harm
    case child_safety
    case impersonation
    case illegal
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spam: return "Spam"
        case .harassment: return "Harassment or bullying"
        case .hate: return "Hate speech"
        case .violence: return "Violence"
        case .nudity: return "Nudity or sexual content"
        case .self_harm: return "Self-harm"
        case .child_safety: return "Child safety"
        case .impersonation: return "Impersonation"
        case .illegal: return "Something illegal"
        case .other: return "Something else"
        }
    }
}

@MainActor
final class ReportService {

    static let shared = ReportService()
    private let api = APIClient()
    private init() {}

    /// The server's cap on the free-text note (MAX_NOTE in routes/reports.ts). Mirrored so
    /// the sheet can stop the user at the limit rather than letting the server reject a
    /// report they have already written.
    static let maxNoteLength = 1000

    /// Submit a report. Throws on failure so the sheet can say what happened — a report that
    /// silently fails is worse than no report button, because the reporter believes a
    /// moderator is looking at it.
    func submit(target: ReportTarget, reason: ReportReason, note: String) async throws {
        struct Body: Encodable {
            let target_type: String
            let target_id: String
            let reason: String
            let note: String?
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Body(
            target_type: target.type,
            target_id: target.id,
            reason: reason.rawValue,
            // Empty becomes nil rather than "": the column is nullable and an empty string
            // reads to a moderator as "the reporter wrote nothing", which is true, while a
            // stored "" looks like data that was lost.
            note: trimmed.isEmpty ? nil : String(trimmed.prefix(Self.maxNoteLength))
        )
        _ = try await api.request("POST", "reports", body: body) as EmptyResponse
    }
}

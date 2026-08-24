//
//  DPDPService.swift
//  Voiid
//
//  The client half of DPDP data-principal rights: erasure, access, correction, grievance,
//  and the data export.
//
//  ── WHY THIS FILE EXISTS ────────────────────────────────────────────────────────
//  `backend/api/src/routes/dpdp.ts` has shipped `POST /dpdp/requests`, `GET /dpdp/requests`
//  and `GET /dpdp/export` for some time, and NOTHING in the app could reach any of them.
//  Three surfaces meanwhile told the user the feature existed:
//
//    * SettingsSheet's header comment claimed Delete My Account "lives at the bottom of Edit
//      Profile" — it had never been built;
//    * LegalView said it twice, in the consent-withdrawal dialog and in a section footer;
//    * the server's OWN erasure response says "You can delete it yourself at any time from
//      Settings, which starts the same erasure immediately."
//
//  A right the user is told they have and cannot exercise is worse than one that is not
//  advertised. This file, plus the Delete My Account control in EditProfileView, is what
//  makes those three claims true.
//
//  ── AN ERASURE REQUEST IS NOT A DELETION ────────────────────────────────────────
//  `POST /dpdp/requests` OPENS A REQUEST. It queues work for a person and returns a due
//  date; it does not delete the account, and the route says so in its own response note. The
//  UI must not round that up to "deleted" — see `EraseOutcome` below, which carries the due
//  date precisely so the confirmation can state when rather than implying now.
//
//  What the app CAN do immediately is stop this device holding the account: after the
//  request is filed, Delete My Account runs the same `SessionTeardown.wipeLocalAccountState()`
//  + `signOut()` that Log Out does. That is honest — local state really is gone — and it is
//  not a claim about the server.
//

import Foundation

// MARK: - Wire models
//
// EVERY field is optional. Swift's Codable throws `keyNotFound` on an absent key rather than
// yielding nil, so a server that omits a column it has no value for would fail the whole
// decode — and a decode failure here reads to the app as "your erasure request failed",
// which is the one wrong answer on this screen.

/// One row of `dpdp_requests`.
struct DPDPRequest: Decodable, Identifiable, Hashable {
    let id: String?
    /// access | correction | erasure | grievance
    let kind: String?
    /// open | in_progress | closed — the server's vocabulary, not remapped here.
    let status: String?
    let opened_at: String?
    /// The response deadline, written onto the row at creation so it cannot move later.
    let due_at: String?

    /// `Identifiable` needs a non-optional. A row with no id cannot be acted on anyway.
    var identity: String { id ?? UUID().uuidString }
}

/// What the caller needs after filing an erasure request: the row, and the server's own
/// sentence about what did and did not just happen.
struct EraseOutcome {
    let request: DPDPRequest?
    /// The route's `note` field, verbatim. Rendered rather than paraphrased — it is the
    /// server's statement that a request is not a deletion, and rewording it here would be
    /// two places to keep in sync about a compliance claim.
    let note: String?
}

// MARK: - Service

@MainActor
final class DPDPService {
    static let shared = DPDPService()
    private let api = APIClient()
    private init() {}

    private struct RequestEnvelope: Decodable {
        let request: DPDPRequest?
        let note: String?
    }

    private struct RequestListEnvelope: Decodable {
        let requests: [DPDPRequest]?
    }

    private struct RequestBody: Encodable {
        let kind: String
        /// Optional free text. The server caps it at 4000 characters; nothing is trimmed
        /// here, so a server-side rejection surfaces as an error rather than being masked by
        /// a client that silently truncated.
        let note: String?
    }

    /// File a request of any kind.
    ///
    /// The server enforces ONE OPEN REQUEST PER KIND (`idx_dpdp_open_per_kind`) and answers
    /// 409 with the existing row when there already is one. That is not a failure — the user
    /// asked for a thing that is already happening — so callers should render the 409's row
    /// rather than an error. `APIError` carries the status for exactly that.
    func file(kind: String, note: String? = nil) async throws -> EraseOutcome {
        let env: RequestEnvelope = try await api.request(
            "POST", "dpdp/requests", body: RequestBody(kind: kind, note: note))
        return EraseOutcome(request: env.request, note: env.note)
    }

    /// Open an erasure request. The account is NOT deleted by this call — see the file header.
    func requestErasure(note: String? = nil) async throws -> EraseOutcome {
        try await file(kind: "erasure", note: note)
    }

    /// Every request this account has filed, so the user can see that one is already open
    /// instead of filing a second and being told 409.
    func requests() async throws -> [DPDPRequest] {
        let env: RequestListEnvelope = try await api.request("GET", "dpdp/requests")
        return env.requests ?? []
    }

    /// The data export, re-encoded as pretty-printed JSON bytes.
    ///
    /// Decoded through `AnyJSON` rather than into a modelled type: the document's shape is
    /// defined by `EXPORT_SECTIONS` on the server and grows a section whenever a table is
    /// added. A Swift struct here would silently DROP whatever the server added last, which
    /// is the opposite of what an export is for. `AnyJSON` round-trips every key it is given,
    /// known to this build or not.
    func exportData() async throws -> Data {
        let document: AnyJSON = try await api.request("GET", "dpdp/export")
        let encoder = JSONEncoder()
        // Sorted and indented because a human reads this file. An export nobody can read is
        // a compliance artefact rather than a right exercised.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }
}


// MARK: - Shape-preserving JSON

/// Any JSON value, decoded and re-encoded without loss.
///
/// Exists so `exportData()` can hand back exactly what the server sent. Every alternative
/// loses something: a concrete struct drops unknown keys, `[String: String]` drops types, and
/// `Data` alone cannot be pretty-printed for the person reading it.
enum AnyJSON: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([AnyJSON].self) { self = .array(v) }
        else if let v = try? c.decode([String: AnyJSON].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unrecognised JSON value in export")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:            try c.encodeNil()
        case .bool(let v):     try c.encode(v)
        case .number(let v):   try c.encode(v)
        case .string(let v):   try c.encode(v)
        case .array(let v):    try c.encode(v)
        case .object(let v):   try c.encode(v)
        }
    }
}

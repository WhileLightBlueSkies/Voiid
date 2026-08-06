//
//  ConsentService.swift
//  Voiid
//
//  The client half of DPDP consent capture. Until this file existed the backend had a
//  consent endpoint that no client had ever called, so `consent_given_at` was null for
//  every account that has ever been created — an endpoint is not a consent flow.
//
//  THE SEQUENCING PROBLEM, AND WHY THERE IS A PENDING RECORD
//  ---------------------------------------------------------
//  The affirmative action happens on the FIRST screen of onboarding: before a phone
//  number, before an OTP, before a JWT. The server cannot record consent for an account
//  that does not exist yet, and asking for consent after sign-in would mean processing
//  the phone number first and asking permission afterwards — the exact inversion DPDP
//  s.5 ("notice at or before") forbids.
//
//  So the tick is recorded LOCALLY the instant it happens, with the notice version and
//  the moment it was given, and posted as soon as there is an account to attach it to.
//  The stored `givenAt` is deliberately NOT sent: an evidence record whose timestamp is
//  client-supplied is one an attacker can backdate, and the gap between the tick and the
//  post is the length of a sign-up. The local timestamp exists so this file can tell a
//  stale pending record (an abandoned sign-up from three weeks ago) from a live one.
//
//  WITHDRAWAL IS AS EASY AS GIVING (s.6(4))
//  ----------------------------------------
//  `withdraw()` takes no arguments, needs no version, and is wired to a single control in
//  Settings → Privacy & Legal. That symmetry is the requirement, not a nicety: a flow
//  where consent is one tap and withdrawal is a support email does not satisfy s.6(4).
//

import Foundation
import Combine

// MARK: - Wire models
//
// EVERY field is optional or defaulted. Swift's Codable throws `keyNotFound` on an absent
// key rather than yielding nil, so a server that adds nothing and simply omits a field it
// has no value for would otherwise fail the whole decode — and a decode failure here
// reads to the app as "consent could not be recorded", which is the one wrong answer.

struct ConsentPurposeInfo: Decodable, Hashable {
    let key: String?
    let required: Bool?
    let summary: String?
}

struct ConsentNoticeInfo: Decodable {
    let version: String?
    let language: String?
    let url: String?
    let published_at: String?
    let content_sha256: String?
    let purposes: [ConsentPurposeInfo]?
}

struct ConsentRecordInfo: Decodable, Hashable {
    let notice_version: String?
    let language: String?
    let purposes: [String: Bool]?
    let given_at: String?
    let given_via: String?
}

struct ConsentStatus: Decodable {
    let consents: [ConsentRecordInfo]?
    let current_notice_version: String?
    let needs_consent: Bool?
}

private struct ConsentEnvelope: Decodable { let consent: ConsentRecordInfo? }
private struct WithdrawEnvelope: Decodable { let withdrawn: [ConsentRecordInfo]? }

// MARK: - Service

@MainActor
final class ConsentService: ObservableObject {
    static let shared = ConsentService()
    private let api = APIClient()
    private let defaults = UserDefaults.standard
    private init() {}

    /// Live consent as the server last reported it. Nil = not yet fetched.
    @Published private(set) var status: ConsentStatus?

    /// True when an authenticated account holds no live consent to the current notice.
    /// Drives the one-time backfill prompt for accounts created before capture existed.
    @Published private(set) var needsBackfill = false

    // MARK: Local pending record

    private enum Key {
        static let pendingVersion = "voiid.consent.pending.version"
        static let pendingLanguage = "voiid.consent.pending.language"
        static let pendingGivenAt = "voiid.consent.pending.givenAt"
        static let pendingPurposes = "voiid.consent.pending.purposes"
    }

    /// A pending record older than this is discarded rather than posted.
    ///
    /// Someone who ticked the box, abandoned sign-up, and came back a month later did not
    /// consent a month ago to whatever the notice says today — and the version they ticked
    /// may since have been retired, in which case the server would reject it anyway. Ask
    /// again instead of posting an answer that has gone stale.
    private let pendingMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Record the affirmative action taken on the onboarding Terms screen.
    ///
    /// Called from the checkbox, not from the Continue button: the consent is the tick,
    /// and a user who ticks and then abandons the flow still ticked. Storing it here also
    /// means a crash between the two does not lose the record.
    func recordLocalConsent(version: String = LegalDocuments.noticeVersion,
                            language: String = LegalDocuments.language,
                            purposes: [String: Bool]) {
        defaults.set(version, forKey: Key.pendingVersion)
        defaults.set(language, forKey: Key.pendingLanguage)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.pendingGivenAt)
        defaults.set(purposes, forKey: Key.pendingPurposes)
    }

    /// The user un-ticked the box before continuing. Drop the record — a withdrawn tick
    /// before sign-up is not a withdrawal, it is an absence of consent, and posting it
    /// later would manufacture agreement that was retracted.
    func clearLocalConsent() {
        [Key.pendingVersion, Key.pendingLanguage, Key.pendingGivenAt, Key.pendingPurposes]
            .forEach(defaults.removeObject(forKey:))
    }

    var hasPendingConsent: Bool { defaults.string(forKey: Key.pendingVersion) != nil }

    // MARK: Server calls

    /// Which notice the server currently publishes. Used to detect that this build's
    /// bundled text is older than what the server expects, in which case the honest move
    /// is to say "update the app" rather than record consent to text we cannot render.
    func fetchCurrentNotice(language: String = LegalDocuments.language) async throws -> ConsentNoticeInfo {
        try await api.request("GET", "consent/notice?language=\(language)", auth: false)
    }

    /// Post consent for the signed-in account. `givenVia` must be one of the values the
    /// server's CHECK constraint allows: app_onboarding, app_settings, backfill_prompt.
    @discardableResult
    func submitConsent(version: String = LegalDocuments.noticeVersion,
                       language: String = LegalDocuments.language,
                       purposes: [String: Bool]? = nil,
                       givenVia: String) async throws -> ConsentRecordInfo? {
        var body: [String: AnyEncodableValue] = [
            "notice_version": .string(version),
            "language": .string(language),
            "given_via": .string(givenVia),
        ]
        if let purposes { body["purposes"] = .booleans(purposes) }
        let env: ConsentEnvelope = try await api.request("POST", "consent", body: body)
        await refreshStatus()
        return env.consent
    }

    /// Flush the onboarding tick once an account exists.
    ///
    /// Idempotent on both sides: the server upserts against the partial unique index, and
    /// the local record is cleared only after a success, so a failed post is retried on
    /// the next launch instead of being silently lost. Never throws — a transient network
    /// failure at sign-up must not block a user from reaching the app, and the record is
    /// still on disk.
    func submitPendingConsent() async {
        guard TokenStore.shared.jwt != nil,
              let version = defaults.string(forKey: Key.pendingVersion) else { return }

        let givenAt = defaults.double(forKey: Key.pendingGivenAt)
        if givenAt > 0, Date().timeIntervalSince1970 - givenAt > pendingMaxAge {
            clearLocalConsent()
            return
        }

        let language = defaults.string(forKey: Key.pendingLanguage) ?? LegalDocuments.language
        let purposes = defaults.dictionary(forKey: Key.pendingPurposes) as? [String: Bool]
        do {
            _ = try await submitConsent(version: version, language: language,
                                        purposes: purposes, givenVia: "app_onboarding")
            clearLocalConsent()
        } catch let error as APIError {
            // A 400 means the server will never accept this record (unknown or retired
            // notice version). Retrying it forever would keep the backfill prompt
            // suppressed behind a pending record that cannot land, so drop it and let the
            // backfill path ask again with a version the server does publish.
            if case .http(let status, _, _) = error, status == 400 {
                clearLocalConsent()
            }
        } catch {
            // Transport failure: keep the record, try next launch.
        }
    }

    /// Withdraw every live consent. One call, no arguments — see the header.
    @discardableResult
    func withdraw(via: String = "app_settings") async throws -> Int {
        let body: [String: AnyEncodableValue] = ["withdrawn_via": .string(via)]
        let env: WithdrawEnvelope = try await api.request("POST", "consent/withdraw", body: body)
        await refreshStatus()
        return env.withdrawn?.count ?? 0
    }

    /// Refresh `status` and `needsBackfill`. Safe to call when signed out (it no-ops).
    func refreshStatus() async {
        guard TokenStore.shared.jwt != nil else {
            status = nil
            needsBackfill = false
            return
        }
        do {
            let fresh: ConsentStatus = try await api.request(
                "GET", "consent/me?language=\(LegalDocuments.language)")
            status = fresh
            // Suppressed while a pending onboarding record is still waiting to be posted:
            // prompting someone who ticked the box thirty seconds ago, because the post
            // has not landed yet, is the app calling the user a liar.
            needsBackfill = (fresh.needs_consent ?? false) && !hasPendingConsent
        } catch {
            // Leave the previous answer in place. Guessing "needs consent" on a network
            // error would put a blocking prompt in front of every user during an outage.
        }
    }

    /// One call for app launch: flush anything pending, then ask where we stand.
    func syncOnLaunch() async {
        await submitPendingConsent()
        await refreshStatus()
    }
}

// MARK: - Encoding helper

/// The API client takes an `Encodable` body, and `[String: Any]` is not one. This is the
/// smallest thing that lets one request carry both strings and a purposes map without
/// declaring a struct per call site.
enum AnyEncodableValue: Encodable {
    case string(String)
    case booleans([String: Bool])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .booleans(let value): try container.encode(value)
        }
    }
}

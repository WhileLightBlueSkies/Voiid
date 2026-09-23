//
//  KycService.swift
//  Voiid
//
//  Host verification — the gate in front of selling tickets (routes/kyc.ts). Mirrors Android
//  `KycService.kt`.
//
//  ── WHAT LEAVES THE PHONE, AND WHAT COMES BACK ──────────────────────────────────
//  The PAN and the bank account number are sent ONCE, in `verify`, over TLS to our API, which
//  passes them to Cashfree Secure ID and Cashfree's payout onboarding in that same request and
//  keeps only the last four characters. Nothing here caches them: the form's fields are the
//  only copy on the device, and they are cleared when the request returns.
//
//  Documents go straight from the phone to private storage through a presigned PUT. The API
//  never serves them back to the app — only the admin panel can open them, one logged view at a
//  time.
//

import Foundation
import UIKit

@MainActor
final class KycService {
    static let shared = KycService()
    private init() {}

    private let api = APIClient()

    struct Document: Decodable, Identifiable, Equatable {
        let id: String
        let kind: String
        let mime: String?
        let uploaded_at: String?
    }

    /// Where this host stands. `status` is not_started | draft | pending_review | verified |
    /// rejected; an unknown word from a newer server is treated as "not verified".
    struct Verification: Decodable, Equatable {
        let status: String
        let legal_name: String?
        let email: String?
        let pan_last4: String?
        let pan_registered_name: String?
        let bank_last4: String?
        let ifsc: String?
        let bank_name: String?
        /// "bank" or "upi" — where this host's share is paid.
        let payout_method: String?
        /// For UPI: "ra•••@okhdfcbank". Voiid never keeps the full ID.
        let upi_masked: String?
        let submitted_at: String?
        let reviewed_at: String?
        let rejection_reason: String?
        let documents: [Document]?
        /// False when the server has no verification provider configured. The screen then says
        /// paid events aren't available yet instead of offering a form that can only fail.
        let available: Bool?

        var isVerified: Bool { status == "verified" }
        var isInReview: Bool { status == "pending_review" }
        var isRejected: Bool { status == "rejected" }
    }

    private struct Envelope: Decodable { let verification: Verification }

    func me() async throws -> Verification {
        let env: Envelope = try await api.request("GET", "kyc/me")
        return env.verification
    }

    /// Exactly one payout destination: a bank account (`bank_account` + `ifsc`) or a UPI ID.
    struct VerifyInput: Encodable {
        let legal_name: String
        let email: String
        let pan: String
        let payout_method: String
        let bank_account: String?
        let ifsc: String?
        let upi_id: String?
    }

    func verify(_ input: VerifyInput) async throws -> Verification {
        let env: Envelope = try await api.request("POST", "kyc/verify", body: input)
        return env.verification
    }

    enum DocumentKind: String, CaseIterable, Identifiable {
        case pan_card, bank_proof, institution_letter, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pan_card:           "PAN card"
            case .bank_proof:         "Cancelled cheque or bank statement"
            case .institution_letter: "Letter from your institution"
            case .other:              "Something else"
            }
        }
    }

    /// Presign → PUT → confirm. A document is only shown to a reviewer once `confirm` has seen
    /// the object land, so a dropped upload never becomes an empty row in the review queue.
    func upload(_ image: UIImage, kind: DocumentKind) async throws {
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            throw APIError.http(status: 400, message: "Couldn\u{2019}t read that photo.")
        }
        struct Body: Encodable { let kind: String; let mime: String }
        struct Presigned: Decodable {
            struct Doc: Decodable { let id: String }
            let document: Doc
            let upload_url: String
        }
        let p: Presigned = try await api.request("POST", "kyc/documents",
                                                 body: Body(kind: kind.rawValue, mime: "image/jpeg"))
        guard let url = URL(string: p.upload_url) else {
            throw APIError.http(status: 500, message: "Upload failed. Try again.")
        }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: put, from: jpeg)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw APIError.http(status: 502, message: "Upload failed. Try again.")
        }
        struct Ok: Decodable { let ok: Bool? }
        let _: Ok = try await api.request("POST", "kyc/documents/\(p.document.id)/confirm")
    }

    func removeDocument(id: String) async throws {
        struct Ok: Decodable { let ok: Bool? }
        let _: Ok = try await api.request("DELETE", "kyc/documents/\(id)")
    }
}

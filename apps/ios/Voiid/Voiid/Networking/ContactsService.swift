//
//  ContactsService.swift
//  Voiid
//
//  Privacy-preserving contact discovery (Section 2.3 / 4.8).
//   - The address book is read ON DEVICE only.
//   - Each phone number is normalized to E.164 and SHA-256 hashed locally.
//   - We upload ONLY the hashes (/contacts/discover) — raw numbers NEVER leave
//     the device. The server returns the hits (VOIID users) and never learns the
//     contacts that aren't on VOIID.
//   - Matched users are then linked via /contacts/sync (resolved user_ids only).
//
//  E.164 normalization here is best-effort (defaults to +91 for national-format
//  numbers, matching our launch region). A proper libPhoneNumber pass is a later
//  hardening step; mis-normalized numbers simply won't match (no privacy impact).
//

import Foundation
import Contacts
import CryptoKit

/// A VOIID user discovered from the address book.
struct VContact: Identifiable, Hashable {
    var id: String { userId }
    let userId: String
    let displayName: String
    let photoURL: String?
}

/// A device contact that is NOT on VOIID (offered for invite).
struct InviteContact: Identifiable, Hashable {
    var id: String { number }
    let name: String
    let number: String
}

@MainActor
final class ContactsService {
    static let shared = ContactsService()
    private let api = APIClient()
    private init() {}

    /// Launch region default for national-format numbers (no leading "+").
    private let defaultCountryCode = "+91"

    struct DiscoveryResult {
        var matches: [VContact]      // on VOIID
        var invites: [InviteContact] // not on VOIID
    }

    /// Request access, read contacts, discover VOIID users, and persist the links.
    func discover() async throws -> DiscoveryResult {
        let store = CNContactStore()
        let granted = try await store.requestAccess(for: .contacts)
        guard granted else { throw APIError.http(status: 403, message: "Contacts permission denied") }

        // 1. Read device contacts (name + phone numbers) on a background queue.
        let device = try await readDeviceContacts(store)

        // 2. Normalize + hash locally; keep a hash → (name, number) map.
        var hashToContact: [String: (name: String, number: String)] = [:]
        for c in device {
            for raw in c.numbers {
                guard let e164 = normalizeE164(raw) else { continue }
                let h = sha256Hex(e164)
                if hashToContact[h] == nil { hashToContact[h] = (c.name, e164) }
            }
        }
        let hashes = Array(hashToContact.keys)
        guard !hashes.isEmpty else { return DiscoveryResult(matches: [], invites: []) }

        // 3. Upload ONLY the hashes (batch <= 2000 per call).
        var matched: [DiscoverMatch] = []
        for batch in hashes.chunked(into: 2000) {
            let env: DiscoverEnvelope = try await api.request(
                "POST", "contacts/discover", body: DiscoverBody(phone_hashes: batch))
            matched.append(contentsOf: env.matches)
        }

        // 4. Build the on-VOIID list (prefer the saved address-book name).
        let myId = TokenStore.shared.userId
        var seenUsers = Set<String>()
        var matches: [VContact] = []
        var matchedHashes = Set<String>()
        for m in matched where m.user_id != myId {
            matchedHashes.insert(m.phone_hash)
            guard !seenUsers.contains(m.user_id) else { continue }
            seenUsers.insert(m.user_id)
            let savedName = hashToContact[m.phone_hash]?.name
            matches.append(VContact(userId: m.user_id,
                                    displayName: savedName ?? m.full_name ?? "VOIID user",
                                    photoURL: m.photo_url))
        }

        // 5. Persist the resolved links (user_ids only — never raw numbers).
        if !matches.isEmpty {
            let body = SyncBody(contacts: matches.map {
                SyncContact(contact_user_id: $0.userId, saved_name: $0.displayName)
            })
            _ = try? await api.request("POST", "contacts/sync", body: body) as EmptyResponse
        }

        // 6. The rest are invite candidates (not on VOIID).
        var invites: [InviteContact] = []
        var seenNumbers = Set<String>()
        for (h, info) in hashToContact where !matchedHashes.contains(h) {
            guard !seenNumbers.contains(info.number) else { continue }
            seenNumbers.insert(info.number)
            invites.append(InviteContact(name: info.name, number: info.number))
        }
        invites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return DiscoveryResult(matches: matches.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
                               invites: invites)
    }

    // MARK: - Device read

    private struct DeviceContact { let name: String; let numbers: [String] }

    private func readDeviceContacts(_ store: CNContactStore) async throws -> [DeviceContact] {
        try await Task.detached(priority: .userInitiated) {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                        CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            var out: [DeviceContact] = []
            try store.enumerateContacts(with: req) { c, _ in
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let nums = c.phoneNumbers.map { $0.value.stringValue }
                if !nums.isEmpty {
                    out.append(DeviceContact(name: name.isEmpty ? (nums.first ?? "Unknown") : name, numbers: nums))
                }
            }
            return out
        }.value
    }

    // MARK: - Normalization + hashing

    func normalizeE164(_ raw: String) -> String? {
        var s = raw.filter { $0.isNumber || $0 == "+" }
        if s.hasPrefix("+") { return s.count > 6 ? s : nil }
        while s.hasPrefix("0") { s.removeFirst() }
        guard !s.isEmpty, s.count >= 6 else { return nil }
        return defaultCountryCode + s
    }

    private func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - DTOs

    private struct DiscoverBody: Encodable { let phone_hashes: [String] }
    private struct DiscoverEnvelope: Decodable { let matches: [DiscoverMatch] }
    private struct DiscoverMatch: Decodable {
        let user_id: String
        let phone_hash: String
        let full_name: String?
        let photo_url: String?
    }
    private struct SyncContact: Encodable { let contact_user_id: String; let saved_name: String? }
    private struct SyncBody: Encodable { let contacts: [SyncContact] }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

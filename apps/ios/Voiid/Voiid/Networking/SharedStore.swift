//
//  SharedStore.swift
//  Voiid
//
//  Cross-process (main app <-> Notification Service Extension) shared state.
//
//  The NSE runs in a SEPARATE process from the app. To decrypt an incoming
//  message in the extension WITHOUT double-decrypting (which would desync the
//  Double Ratchet and make future messages undecryptable) both processes must
//  read/write the SAME crypto state and coordinate through a single-writer lock:
//
//   * AppGroup          — the shared on-disk container (decrypted-message store,
//                         the cross-process lock file). Both targets carry the
//                         `group.com.voiid.app` App Groups entitlement.
//   * SharedKeychain    — the shared keychain ACCESS GROUP that both targets can
//                         read (identity pickle, session pickles, pickle keys,
//                         auth JWT). The app's PRIVATE keychain items are migrated
//                         into this access group on first run (see KeychainData).
//   * CrossProcessLock  — an flock(2) advisory lock on an app-group file. Held
//                         across the whole fetch→decrypt→persist critical section
//                         so the app and the NSE can never decrypt the same
//                         ratchet concurrently (Signal's single-writer model,
//                         implemented on our vodozemac/keychain storage instead
//                         of a shared SQLite).
//

import Foundation
import GRDB
import Security

// MARK: - App Group container

enum AppGroup {
    /// Shared App Group id — declared in BOTH targets' entitlements. Files written
    /// here are visible to the main app and the NSE.
    static let identifier = "group.com.voiid.app"

    /// The shared container URL, or nil if the entitlement is missing (which should
    /// never happen in a correctly-provisioned build; callers fall back gracefully).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Decrypted-message store (moved out of the app-private Application Support dir
    /// so the NSE can read/append the SAME store — decrypt-once across processes).
    static var messageStoreURL: URL? {
        containerURL?.appendingPathComponent("voiid_messages.json")
    }

    /// The file the cross-process lock is taken on (contents are irrelevant).
    static var lockURL: URL? {
        containerURL?.appendingPathComponent("voiid_decrypt.lock")
    }
}

// MARK: - Shared local directory (names, resolvable without the app)

/// Read-only access to the local user directory + conversation titles from ANY process,
/// including the Notification Service Extension.
///
/// WHY THIS EXISTS RATHER THAN `UserDirectory`: a notification must never show a raw user
/// id, and the name a user actually expects to see is the one from THIS device's address
/// book (`saved_name`) — which only exists locally. `UserDirectory` is the app's canonical
/// resolver, but it is a @MainActor ObservableObject that drags in the whole storage layer
/// plus `CallManager` (for E.164 normalisation); the NSE compiles a handful of networking
/// files inside a 24 MB budget and cannot afford that graph. The `users` and
/// `conversations` tables it mirrors already live in the SAME app-group database, so the
/// extension applies the same precedence to the same rows without the objects.
///
/// The precedence below MUST stay in step with `DirectoryUser.displayName`:
///   saved_name → full_name → phone_e164 → username → caller's fallback → "Unknown".
/// A raw user id is never an acceptable answer.
enum SharedDirectory {
    /// Opened lazily and only if the app has already created the database — opening a
    /// missing path would MINT an empty, un-migrated file that the app then has to
    /// migrate from scratch. No writes ever happen through this handle.
    private static let queue: DatabaseQueue? = {
        guard let url = AppGroup.containerURL?.appendingPathComponent("voiid.sqlite"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        var config = Configuration()
        // Names and conversation titles pass through here; never let them reach the log.
        config.publicStatementArguments = false
        return try? DatabaseQueue(path: url.path, configuration: config)
    }()

    private static func read<T>(_ block: (Database) throws -> T) -> T? {
        guard let queue else { return nil }
        return try? queue.read(block)
    }

    /// The name to show for a user id. `fallback` is normally the server-supplied
    /// `full_name` from the conversation payload — used only when we have no local row.
    static func displayName(_ userId: String, fallback: String? = nil) -> String {
        let row = read { db in
            try Row.fetchOne(db, sql: """
                select saved_name, full_name, phone_e164, username from users where user_id = ?
                """, arguments: [userId])
        } ?? nil
        var candidates: [String?] = []
        if let row {
            // `as String?` selects GRDB's NULL-tolerant subscript. The non-optional overload
            // traps on a NULL column, and every one of these columns is nullable — a name
            // lookup must never be able to crash the extension.
            candidates = [row["saved_name"] as String?, row["full_name"] as String?,
                          row["phone_e164"] as String?, row["username"] as String?]
        }
        candidates.append(fallback)
        for c in candidates {
            if let c = c?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty, c != userId {
                return c
            }
        }
        return "Unknown"
    }

    /// A conversation's locally-stored title. Authoritative for GROUPS only (a direct
    /// chat's title is derived from the peer at read time), which is exactly the case
    /// that needs it: the group name to put in a notification title.
    static func conversationTitle(_ conversationId: String) -> String? {
        let title = read { db in
            try String.fetchOne(db, sql: "select title from conversations where id = ?",
                                arguments: [conversationId])
        } ?? nil
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

// MARK: - Shared keychain access group

/// Resolves the fully-qualified shared keychain access group at runtime WITHOUT
/// hardcoding the 10-char Team ID. The group string stored in the keychain is
/// `<AppIdentifierPrefix>com.voiid.shared` (e.g. `CV7L84G776.com.voiid.shared`);
/// the prefix is discovered with the standard "probe" trick (Apple's GenericKeychain
/// sample): add a throwaway item with no access group, read back its resolved
/// `kSecAttrAccessGroup`, and take everything up to and including the first dot.
enum SharedKeychain {
    /// The unqualified group name — must match the `keychain-access-groups`
    /// entitlement entry `$(AppIdentifierPrefix)com.voiid.shared` in both targets.
    static let groupSuffix = "com.voiid.shared"

    /// Cached fully-qualified access group (`TEAMID.com.voiid.shared`).
    static let group: String? = {
        guard let prefix = appIdentifierPrefix() else { return nil }
        return prefix + groupSuffix
    }()

    private static func appIdentifierPrefix() -> String? {
        let probeAccount = "voiid_prefix_probe"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: probeAccount,
            kSecAttrService as String: "voiid.prefix.probe",
            kSecReturnAttributes as String: true,
            kSecValueData as String: Data("x".utf8),
        ]
        // Clean any stale probe, then add + read back its resolved access group.
        SecItemDelete(query as CFDictionary)
        var out: CFTypeRef?
        var status = SecItemAdd(query as CFDictionary, &out)
        if status == errSecSuccess, let attrs = out as? [String: Any],
           let group = attrs[kSecAttrAccessGroup as String] as? String {
            SecItemDelete(query as CFDictionary)
            if let dot = group.firstIndex(of: ".") {
                return String(group[...dot])   // "TEAMID."
            }
        }
        // Fallback: re-query the probe for its attributes if the add raced.
        query[kSecValueData as String] = nil
        status = SecItemCopyMatching(query as CFDictionary, &out)
        SecItemDelete(query as CFDictionary)
        if status == errSecSuccess, let attrs = out as? [String: Any],
           let group = attrs[kSecAttrAccessGroup as String] as? String,
           let dot = group.firstIndex(of: ".") {
            return String(group[...dot])
        }
        return nil
    }
}

// MARK: - Cross-process single-writer lock

/// A cross-process advisory lock backed by flock(2) on an app-group file.
///
/// We use flock rather than NSFileCoordinator because the critical section is a
/// LONG, async span (network fetch + ratchet decrypt + keychain persistence).
/// NSFileCoordinator is designed for short, synchronous coordinated file access;
/// holding its coordination block open across multiple `await`s is an anti-pattern.
/// An flock fd, by contrast, can be held safely across suspension points and is a
/// true cross-process mutex — exactly the single-writer guarantee we need so the
/// app and the NSE never advance the same ratchet at once.
enum CrossProcessLock {
    /// Run `body` while holding the exclusive cross-process lock. Acquisition blocks
    /// on a background thread (so the calling actor isn't stalled), then `body` runs
    /// on the caller's actor. The lock is always released, even on throw.
    static func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        let fd = await acquire()
        defer { release(fd) }
        return try await body()
    }

    private static func acquire() async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let path = AppGroup.lockURL?.path else {
                    cont.resume(returning: -1)   // no container → degrade to no lock
                    return
                }
                let fd = open(path, O_CREAT | O_RDWR, 0o644)
                if fd >= 0 { _ = flock(fd, LOCK_EX) }   // blocks until exclusive
                cont.resume(returning: fd)
            }
        }
    }

    private static func release(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
    }
}

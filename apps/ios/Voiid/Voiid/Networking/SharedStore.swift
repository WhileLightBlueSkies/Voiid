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

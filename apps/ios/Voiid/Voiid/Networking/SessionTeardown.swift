//
//  SessionTeardown.swift
//  Voiid
//
//  Removes this account's local footprint from the device.
//
//  WHY THIS EXISTS
//  ---------------
//  `AppSession.signOut()` clears the JWT and the profile UserDefaults key and nothing
//  else. Everything that actually holds the user's data survived it:
//
//   * the app-group SQLite store (`voiid.sqlite` + `-wal`/`-shm`) — and because
//     `ChatStore.loadConversations()` is local-first, the NEXT account to sign in on this
//     device rendered the previous user's conversations, messages and call history;
//   * `voiid_messages.json`, the plaintext decrypted-message blob;
//   * the E2E keychain (identity pickle, Olm session pickles, MLS state, and the backup
//     master secret);
//   * the registered VoIP push token, so the handset kept ringing for the account that
//     had signed out.
//
//  A polished, confirmed "Log Out" row sitting on top of that would make the leak more
//  prominent, not less. So log-out and teardown ship together, or neither ships.
//
//  ORDERING IS LOAD-BEARING
//  ------------------------
//  The auth token is NOT cleared here. Callers clear it afterwards (via
//  `AppSession.signOut()`), because step 1 below is an authenticated request and must go
//  out while the JWT still exists.
//
//  Every step is best-effort and independent: a failure in one must not prevent the rest.
//  Half a teardown is strictly worse than a slow one.
//

import Foundation

enum SessionTeardown {

    /// Wipe every local trace of the signed-in account. Call this BEFORE clearing the
    /// auth token — `AppSession.signOut()` immediately after is the intended sequence.
    ///
    /// Used by Log Out (`SettingsSheet`) and by Delete My Account (`EditProfileView`),
    /// which needs exactly the same local wipe after the server-side delete.
    @MainActor
    static func wipeLocalAccountState() async {
        await unregisterVoIPToken()   // 1 — needs the JWT, so it goes first
        wipeKeychain()                // 2
        wipeInMemoryState()           // 3 — BEFORE the files, or a flush rewrites them
        deleteLocalFiles()            // 4
        reopenEmptyDatabase()         // 5
        resetLegacyImportFlag()       // 6
        clearCaches()                 // 7
        MissedCallNotifier.cancelAll()// 8 — daemon-held banners outlive the process
        // 9 — the caller clears TokenStore / calls auth.logout().
    }

    // MARK: - 3. In-memory state
    //
    // Deleting files is only half a teardown: signing out does NOT restart the process, so
    // every in-memory copy of the previous account's data survives into the next session.
    // This step must run BEFORE deleteLocalFiles(), because any of these holders could
    // otherwise flush its stale contents back to disk after the delete.

    @MainActor
    private static func wipeInMemoryState() {
        // Plaintext messages and live Olm sessions.
        ChatEngine.shared.wipeInMemoryState()
        // Contact names, phone numbers and photos from the previous user's address book.
        UserDirectory.shared.wipe()
        // The once-per-process bootstrap latch and the in-memory identity: without this the
        // next account's bootstrap() returns immediately and reuses the old identity.
        E2EManager.shared.resetForSignOut()
        // Close the database BEFORE unlinking its files — see closeForTeardown().
        VoiidDatabase.shared.closeForTeardown()
    }

    // MARK: - 5. Fresh database

    /// The process keeps running, so hand the next sign-in a working, empty database rather
    /// than leaving every local read disabled for the rest of the session.
    @MainActor
    private static func reopenEmptyDatabase() {
        VoiidDatabase.shared.reopenAfterTeardown()
    }

    // MARK: - 1. VoIP token

    /// Tell the backend to stop sending VoIP pushes to this device. The route explicitly
    /// accepts a null token as "unregister".
    ///
    /// Failure is ignored: we are signing out either way, and blocking a log-out on a
    /// network round-trip would be a worse bug than a stale push token. Worst case the
    /// next sign-in on this device overwrites the row.
    @MainActor
    private static func unregisterVoIPToken() async {
        guard TokenStore.shared.jwt != nil,
              let deviceId = E2EManager.shared.deviceId else { return }
        struct Body: Encodable {
            let device_id: String
            let voip_token: String?
        }
        _ = try? await APIClient().request("POST", "devices/voip-token",
                                           body: Body(device_id: deviceId, voip_token: nil),
                                           as: EmptyResponse.self)
    }

    // MARK: - 2. Keychain

    /// The iOS keychain survives app uninstall, so leaving these behind means a reinstall
    /// (or a different account on the same handset) resurrects a stale identity.
    ///
    /// `clearMasterSecret()` is called explicitly as well as wiping `com.voiid.e2e`: it is
    /// the one item whose loss the user was warned about in the confirmation dialog, and
    /// stating it here keeps that promise findable.
    @MainActor
    private static func wipeKeychain() {
        E2EManager.shared.clearMasterSecret()
        for service in ["com.voiid.e2e", "com.voiid.sessions", "com.voiid.mls"] {
            KeychainData(service: service).wipeService()
        }
    }

    // MARK: - 3. Local files

    /// The database and the decrypted-message blob, in both their app-group location and
    /// the Application Support fallback an unentitled build would have used.
    private static func deleteLocalFiles() {
        let fm = FileManager.default
        var targets: [URL] = []

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first

        for base in [AppGroup.containerURL, appSupport].compactMap({ $0 }) {
            let db = base.appendingPathComponent("voiid.sqlite")
            targets.append(db)
            targets.append(URL(fileURLWithPath: db.path + "-wal"))
            targets.append(URL(fileURLWithPath: db.path + "-shm"))
            targets.append(base.appendingPathComponent("voiid_messages.json"))
            // Phase 2: the per-conversation message shards live under messages/.
            targets.append(base.appendingPathComponent("messages", isDirectory: true))
        }

        for url in targets {
            try? fm.removeItem(at: url)   // removeItem deletes a directory recursively
        }
    }

    // MARK: - 4. Legacy import flag

    /// `LocalStore.importLegacyMessageBlobIfNeeded()` is gated on this flag and runs
    /// exactly once per install. Leaving it set means a future account on this device
    /// silently never runs the legacy import.
    private static func resetLegacyImportFlag() {
        // Mirrors LocalStore.importFlagKey, which is private to that type.
        UserDefaults.standard.removeObject(forKey: "voiid.localstore.imported_message_blob_v1")
    }

    // MARK: - 5. Caches

    /// In-memory decrypted media and the URL cache both hold the previous account's
    /// content until the process dies. Sign-out does not restart the process.
    @MainActor
    private static func clearCaches() {
        URLCache.shared.removeAllCachedResponses()
        MediaCache.shared.clear()
        AvatarCache.clear()   // previous account's faces must not survive into the next login
    }
}

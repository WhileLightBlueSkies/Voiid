package com.voiid.app.net

import android.content.Context
import uniffi.voiid.decryptBackup
import uniffi.voiid.encryptBackup
import uniffi.voiid.generateMasterSecret
import uniffi.voiid.masterSecretToPhrase
import uniffi.voiid.phraseToMasterSecret
import uniffi.voiid.unwrapMasterSecretWithPin
import uniffi.voiid.wrapMasterSecretWithPin

/**
 * High-level backup / recovery orchestration — ties the FFI crypto to the network
 * services and local stores so the UI stays thin. All heavy work (crypto + network)
 * runs off the main thread; call these from a coroutine on Dispatchers.IO.
 *
 * Every FFI call can throw [uniffi.voiid.E2eFfiException] (GCM auth: wrong PIN /
 * tampered blob / bad phrase); callers wrap in try/catch and surface a message.
 */
class BackupManager(context: Context) {
    private val appContext = context.applicationContext
    private val recovery = RecoveryService(appContext)
    private val backup = BackupService(appContext)
    private val drive = GoogleDriveBackupService(appContext)
    private val store = RecoveryStore.get(appContext)
    private val engine = ChatEngine.get(appContext)

    /** Where a restore pulls the encrypted blob from. The master secret always comes from
     *  PIN/phrase regardless — only the blob storage location differs. */
    enum class RestoreSource { SERVER, DRIVE }

    /** Whether backup has already been set up (or restored) on THIS device. */
    fun isSetUp(): Boolean = store.hasMasterSecret()

    /** Current backup metadata from the server (null if none). */
    suspend fun fetchMeta(): BackupService.BackupMeta? = backup.fetchBackupMeta()

    /**
     * Fresh secret + its 24-word phrase for the setup screen to DISPLAY. Nothing is
     * persisted or uploaded yet — the user confirms they've saved the phrase, then
     * [finalizeSetup] commits it. Throws if phrase derivation fails.
     */
    fun newSecretAndPhrase(): Pair<ByteArray, String> {
        val secret = generateMasterSecret()
        val phrase = masterSecretToPhrase(secret)
        return secret to phrase
    }

    /**
     * Commit a new backup: PIN-wrap the secret → PUT /recovery/key → persist the secret
     * locally → run the first backup. Throws on any failure (nothing half-persisted:
     * we save locally only after the key upload succeeds).
     */
    suspend fun finalizeSetup(secret: ByteArray, pin: String) {
        val wrapped = wrapMasterSecretWithPin(secret, pin)
        recovery.putKey(wrapped)
        store.saveMasterSecret(secret)
        runBackup(secret)
    }

    /** Encrypt the current message store under the local secret and upload it. */
    suspend fun backupNow() {
        val secret = store.loadMasterSecret()
            ?: throw ApiError.Http(0, "Set up backup first.")
        runBackup(secret)
    }

    private suspend fun runBackup(secret: ByteArray) {
        val blob = encryptBackup(secret, engine.exportStore())
        // Server is the always-available default destination.
        backup.uploadBackup(blob)
        // Google Drive is an ADDITIONAL, opt-in destination for the SAME ciphertext.
        // Defensive: a Drive failure (token expired, offline, revoked grant) must never
        // break or roll back the server backup — swallow it here. The explicit
        // enable/backup entry points below surface Drive errors to the user directly.
        if (store.isDriveEnabled()) {
            runCatching { drive.uploadBackup(blob) }
        }
    }

    // MARK: - Google Drive destination

    /** Google Sign-In client (drive.appdata scope) for the UI to launch the consent flow. */
    fun driveSignInClient() = drive.signInClient()

    /** True if a Google account is signed in AND granted the drive.appdata scope. */
    fun isDriveSignedIn(): Boolean = drive.isSignedIn()

    /** True if Drive backup is opted-in on this device (independent of the server backup). */
    fun isDriveEnabled(): Boolean = store.isDriveEnabled()

    /** Latest Drive backup metadata, or null (not signed in / none / failure). */
    suspend fun fetchDriveMeta(): GoogleDriveBackupService.DriveBackupMeta? =
        if (drive.isSignedIn()) runCatching { drive.fetchBackupMeta() }.getOrNull() else null

    /**
     * Turn on the Drive destination: encrypt the current store and push the SAME blob to
     * Drive, then persist the opt-in. Surfaces auth/transfer errors to the caller (unlike
     * the silent Drive leg of [runBackup]) so the UI can report a failed sign-in/upload.
     * Requires backup to already be set up (a master secret exists locally).
     */
    suspend fun enableDriveBackup() {
        val secret = store.loadMasterSecret()
            ?: throw ApiError.Http(0, "Set up backup first.")
        val blob = encryptBackup(secret, engine.exportStore())
        drive.uploadBackup(blob)
        store.setDriveEnabled(true)
    }

    /** Turn off the Drive destination and sign out locally (the user's Drive blob is left intact). */
    fun disableDriveBackup() {
        store.setDriveEnabled(false)
        drive.signOut()
    }

    /** The 24-word recovery phrase for the locally-stored secret (View recovery phrase). */
    fun recoveryPhrase(): String? =
        store.loadMasterSecret()?.let { masterSecretToPhrase(it) }

    /** Re-wrap the local secret under a NEW PIN and upload it (Change PIN). */
    suspend fun changePin(newPin: String) {
        val secret = store.loadMasterSecret()
            ?: throw ApiError.Http(0, "Set up backup first.")
        recovery.putKey(wrapMasterSecretWithPin(secret, newPin))
    }

    // MARK: - Restore (returning user on a new device)

    /** GET /recovery/key state, so the restore UI can show locked/never-set up front. */
    suspend fun recoveryKeyState(): RecoveryService.KeyResult = recovery.getKey()

    /**
     * Restore using the numeric PIN. Fetches the wrapped key, unwraps it (throws on
     * wrong PIN → reported as a failed attempt), then downloads + decrypts + imports the
     * backup and persists the secret locally. Returns [RestoreOutcome].
     */
    suspend fun restoreWithPin(pin: String, source: RestoreSource = RestoreSource.SERVER): RestoreOutcome {
        when (val res = recovery.getKey()) {
            is RecoveryService.KeyResult.NotSet -> return RestoreOutcome.NoRecoveryKey
            is RecoveryService.KeyResult.Locked -> return RestoreOutcome.Locked(res.retryAfterSeconds)
            is RecoveryService.KeyResult.Found -> {
                val secret = try {
                    unwrapMasterSecretWithPin(res.wrapped, pin)
                } catch (e: Exception) {
                    recovery.reportAttempt(false)
                    return RestoreOutcome.WrongPin
                }
                recovery.reportAttempt(true)
                applyRestore(secret, source)
                return RestoreOutcome.Success
            }
        }
    }

    /**
     * Restore using the 24-word recovery phrase. Validates the phrase (BIP39) via
     * [phraseToMasterSecret] — throws [uniffi.voiid.E2eFfiException] on an invalid phrase.
     */
    suspend fun restoreWithPhrase(phrase: String, source: RestoreSource = RestoreSource.SERVER): RestoreOutcome {
        val secret = phraseToMasterSecret(phrase.trim())   // throws on invalid phrase
        applyRestore(secret, source)
        return RestoreOutcome.Success
    }

    /** Download (from [source]) → decrypt → import the backup and persist the secret locally. */
    private suspend fun applyRestore(secret: ByteArray, source: RestoreSource) {
        val blob = when (source) {
            RestoreSource.SERVER -> backup.downloadBackup()
            RestoreSource.DRIVE -> drive.downloadBackup()
        }
        val plaintext = decryptBackup(secret, blob)   // throws if secret doesn't match the blob
        engine.importStore(plaintext)
        store.saveMasterSecret(secret)
    }

    sealed class RestoreOutcome {
        object Success : RestoreOutcome()
        object WrongPin : RestoreOutcome()
        object NoRecoveryKey : RestoreOutcome()
        data class Locked(val retryAfterSeconds: Long?) : RestoreOutcome()
    }
}

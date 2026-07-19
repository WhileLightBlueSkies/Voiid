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
    private val store = RecoveryStore.get(appContext)
    private val engine = ChatEngine.get(appContext)

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
        backup.uploadBackup(blob)
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
    suspend fun restoreWithPin(pin: String): RestoreOutcome {
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
                applyRestore(secret)
                return RestoreOutcome.Success
            }
        }
    }

    /**
     * Restore using the 24-word recovery phrase. Validates the phrase (BIP39) via
     * [phraseToMasterSecret] — throws [uniffi.voiid.E2eFfiException] on an invalid phrase.
     */
    suspend fun restoreWithPhrase(phrase: String): RestoreOutcome {
        val secret = phraseToMasterSecret(phrase.trim())   // throws on invalid phrase
        applyRestore(secret)
        return RestoreOutcome.Success
    }

    /** Download → decrypt → import the backup and persist the secret locally. */
    private suspend fun applyRestore(secret: ByteArray) {
        val blob = backup.downloadBackup()
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

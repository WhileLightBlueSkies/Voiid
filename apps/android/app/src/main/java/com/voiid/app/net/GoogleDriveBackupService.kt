package com.voiid.app.net

import android.content.Context
import android.content.Intent
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.UserRecoverableAuthException
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.Scope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayOutputStream
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/**
 * SECOND, user-owned destination for the SAME encrypted backup blob that
 * [BackupService] pushes to our server. The bytes written here are ALWAYS the
 * `encryptBackup(masterSecret, plaintext)` ciphertext produced in [BackupManager];
 * the master secret and plaintext never leave the device — Google only ever sees
 * opaque ciphertext.
 *
 * Storage is the Drive **`appDataFolder`** — a hidden, app-private folder the user can't
 * browse and other apps can't read. That's why we request the least-privilege
 * `drive.appdata` scope (NOT full Drive): Google can't see the user's other files, and
 * this app can only touch what it created.
 *
 * Transport is Drive v3 REST over the existing OkHttp (mirrors how [BackupService] hits
 * presigned R2 directly) — no heavy Drive client library. The OAuth access token comes
 * from [DriveTokenProvider]; the default implementation uses Google Sign-In +
 * [GoogleAuthUtil]. Sign-in requires the OAuth Android client id / SHA registered in the
 * Google console (docs/GOOGLE_INTEGRATION_TODO.md §2a) — until that console step is done
 * sign-in fails at runtime, but the code compiles and the REST logic is real.
 *
 * All calls are blocking network/crypto work wrapped in [Dispatchers.IO]; call from a
 * coroutine. Failures throw [ApiError.Http] (HTTP status) or propagate the Google auth
 * exception; [DriveAuthRecoverable] carries a consent [Intent] the UI can launch.
 */
class GoogleDriveBackupService(
    context: Context,
    private val tokenProvider: DriveTokenProvider =
        GoogleSignInTokenProvider(context.applicationContext),
) {
    private val appContext = context.applicationContext

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .build()

    /** Metadata for our backup file in the Drive appDataFolder (mirrors [BackupService.BackupMeta]). */
    data class DriveBackupMeta(
        val fileId: String,
        val sizeBytes: Long,
        val modifiedTime: String?,
    )

    @Serializable private data class DriveFile(
        val id: String,
        val name: String? = null,
        val size: String? = null,        // Drive v3 returns size as a decimal string
        val modifiedTime: String? = null,
    )
    @Serializable private data class DriveFileList(val files: List<DriveFile> = emptyList())

    // MARK: - Sign-in surface (used by the UI to launch the consent flow)

    /** Google Sign-In client scoped to `drive.appdata`. The UI launches [GoogleSignInClient.getSignInIntent]. */
    fun signInClient(): GoogleSignInClient {
        val opts = GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestEmail()
            .requestScopes(Scope(DRIVE_APPDATA_SCOPE))
            .build()
        return GoogleSignIn.getClient(appContext, opts)
    }

    /** True if there's a signed-in Google account that granted the `drive.appdata` scope. */
    fun isSignedIn(): Boolean {
        val acct = GoogleSignIn.getLastSignedInAccount(appContext) ?: return false
        return GoogleSignIn.hasPermissions(acct, Scope(DRIVE_APPDATA_SCOPE))
    }

    /** Sign out of Google on this device (revokes local token; the Drive blob itself is untouched). */
    fun signOut() {
        runCatching { signInClient().signOut() }
    }

    // MARK: - Blob transport (same shapes as BackupService)

    /** Upload the encrypted backup blob to appDataFolder — updating the existing file id if present. */
    suspend fun uploadBackup(blob: ByteArray) = withContext(Dispatchers.IO) {
        val token = requireToken()
        val existing = findBackupFile(token)
        if (existing != null) updateMedia(token, existing.id, blob)
        else createMultipart(token, blob)
    }

    /** Metadata for our backup file, or null if not signed in / no backup yet. */
    suspend fun fetchBackupMeta(): DriveBackupMeta? = withContext(Dispatchers.IO) {
        val token = tokenOrNull() ?: return@withContext null
        val f = findBackupFile(token) ?: return@withContext null
        DriveBackupMeta(f.id, f.size?.toLongOrNull() ?: 0L, f.modifiedTime)
    }

    /** Download the encrypted backup blob (`GET files/{id}?alt=media`). */
    suspend fun downloadBackup(): ByteArray = withContext(Dispatchers.IO) {
        val token = requireToken()
        val f = findBackupFile(token) ?: throw ApiError.Http(404, "No Google Drive backup found.")
        val req = Request.Builder()
            .url("https://www.googleapis.com/drive/v3/files/${f.id}?alt=media")
            .header("Authorization", "Bearer $token")
            .get().build()
        execOrThrow(req, "Drive download failed")
    }

    // MARK: - Drive v3 REST internals

    private fun findBackupFile(token: String): DriveFile? {
        val q = URLEncoder.encode("name = '$BACKUP_FILE_NAME'", "UTF-8")
        val fields = URLEncoder.encode("files(id,name,size,modifiedTime)", "UTF-8")
        val req = Request.Builder()
            .url("https://www.googleapis.com/drive/v3/files?spaces=appDataFolder&q=$q&fields=$fields")
            .header("Authorization", "Bearer $token")
            .get().build()
        val bytes = execOrThrow(req, "Drive list failed")
        return ApiClient.json.decodeFromString(DriveFileList.serializer(), String(bytes)).files.firstOrNull()
    }

    /** New file: multipart/related (metadata part pins parents=appDataFolder + name, then the media part). */
    private fun createMultipart(token: String, blob: ByteArray) {
        val boundary = "voiid_" + System.currentTimeMillis()
        val meta = """{"name":"$BACKUP_FILE_NAME","parents":["appDataFolder"]}"""
        val body = ByteArrayOutputStream().apply {
            fun w(s: String) = write(s.toByteArray(Charsets.UTF_8))
            w("--$boundary\r\n")
            w("Content-Type: application/json; charset=UTF-8\r\n\r\n")
            w(meta); w("\r\n")
            w("--$boundary\r\n")
            w("Content-Type: application/octet-stream\r\n\r\n")
            write(blob); w("\r\n")
            w("--$boundary--")
        }.toByteArray()
        val req = Request.Builder()
            .url("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")
            .header("Authorization", "Bearer $token")
            .post(body.toRequestBody("multipart/related; boundary=$boundary".toMediaType()))
            .build()
        execOrThrow(req, "Drive upload failed")
    }

    /** Existing file: replace its bytes only (media upload; parents/name unchanged). */
    private fun updateMedia(token: String, fileId: String, blob: ByteArray) {
        val req = Request.Builder()
            .url("https://www.googleapis.com/upload/drive/v3/files/$fileId?uploadType=media&fields=id")
            .header("Authorization", "Bearer $token")
            .patch(blob.toRequestBody("application/octet-stream".toMediaType()))
            .build()
        execOrThrow(req, "Drive update failed")
    }

    private fun execOrThrow(req: Request, ctx: String): ByteArray {
        client.newCall(req).execute().use {
            if (!it.isSuccessful) throw ApiError.Http(it.code, "$ctx (${it.code}).")
            return it.body?.bytes() ?: ByteArray(0)
        }
    }

    private fun requireToken(): String =
        tokenOrNull() ?: throw ApiError.Http(401, "Sign in to Google Drive first.")

    /** Blocking OAuth token (we're already on Dispatchers.IO); null if no signed-in account. */
    private fun tokenOrNull(): String? = tokenProvider.blockingToken()

    companion object {
        /** Least-privilege Drive scope: app-private folder only — Google can't see the user's other files. */
        const val DRIVE_APPDATA_SCOPE = "https://www.googleapis.com/auth/drive.appdata"
        private const val BACKUP_FILE_NAME = "voiid-backup.enc"
    }
}

/**
 * Seam for OAuth-token acquisition, so the Drive REST logic doesn't hard-depend on the
 * sign-in mechanism. The default [GoogleSignInTokenProvider] uses Google Sign-In +
 * [GoogleAuthUtil]; tests/alt-auth can swap it.
 */
interface DriveTokenProvider {
    /**
     * A fresh OAuth access token for the `drive.appdata` scope, or null if no Google
     * account is signed in on this device. Blocking — call on [Dispatchers.IO].
     * Throws [DriveAuthRecoverable] if the user must (re)consent.
     */
    fun blockingToken(): String?
}

/** Signals the UI to launch [recoveryIntent] to (re)obtain the user's Drive consent. */
class DriveAuthRecoverable(val recoveryIntent: Intent) :
    Exception("Google authorization required")

/** Default provider: reads the last signed-in Google account and mints a token via [GoogleAuthUtil]. */
class GoogleSignInTokenProvider(context: Context) : DriveTokenProvider {
    private val appContext = context.applicationContext

    override fun blockingToken(): String? {
        val account = GoogleSignIn.getLastSignedInAccount(appContext)?.account ?: return null
        return try {
            GoogleAuthUtil.getToken(
                appContext,
                account,
                "oauth2:${GoogleDriveBackupService.DRIVE_APPDATA_SCOPE}",
            )
        } catch (e: UserRecoverableAuthException) {
            val intent = e.intent ?: throw e
            throw DriveAuthRecoverable(intent)
        }
    }
}

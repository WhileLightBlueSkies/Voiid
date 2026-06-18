package com.voiid.app.net

import android.app.Activity
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.PhoneAuthCredential
import com.google.firebase.auth.PhoneAuthOptions
import com.google.firebase.auth.PhoneAuthProvider
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.tasks.await
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Firebase Phone Auth (OTP) — the OTP is sent + verified by Firebase on-device;
 * we then exchange the resulting Firebase ID token for OUR JWT (see AuthService).
 *
 * Flow:
 *   1. sendCode(activity, e164) -> verificationId (Firebase texts the user)
 *   2. verify(verificationId, code) -> Firebase ID token  (then AuthService.loginWithFirebase)
 *
 * Requires the google-services plugin + google-services.json in app/, and the
 * Firebase Console: Phone provider enabled + app SHA-1/256 added (or reCAPTCHA).
 */
object FirebasePhoneAuth {

    private val auth get() = FirebaseAuth.getInstance()

    /**
     * Start verification: Firebase sends the SMS and returns a verificationId.
     * (Auto-retrieval/instant-verification on some devices is ignored here so the
     * UX is the explicit "enter the code" flow, matching iOS.)
     */
    suspend fun sendCode(activity: Activity, e164: String): String =
        suspendCancellableCoroutine { cont ->
            val callbacks = object : PhoneAuthProvider.OnVerificationStateChangedCallbacks() {
                override fun onVerificationCompleted(credential: PhoneAuthCredential) {
                    // Instant verification (some Android devices). We still want the
                    // user-entered-code path to be the single route, so we ignore this
                    // and let them type the code; do nothing here.
                }
                override fun onVerificationFailed(e: com.google.firebase.FirebaseException) {
                    if (cont.isActive) cont.resumeWithException(e)
                }
                override fun onCodeSent(verificationId: String, token: PhoneAuthProvider.ForceResendingToken) {
                    if (cont.isActive) cont.resume(verificationId)
                }
            }
            val options = PhoneAuthOptions.newBuilder(auth)
                .setPhoneNumber(e164)
                .setTimeout(60L, TimeUnit.SECONDS)
                .setActivity(activity)
                .setCallbacks(callbacks)
                .build()
            PhoneAuthProvider.verifyPhoneNumber(options)
        }

    /** Verify the entered code and return the Firebase ID token to send to our backend. */
    suspend fun verify(verificationId: String, code: String): String {
        val credential = PhoneAuthProvider.getCredential(verificationId, code)
        val result = auth.signInWithCredential(credential).await()
        val token = result.user?.getIdToken(false)?.await()?.token
            ?: throw IllegalStateException("No Firebase ID token after sign-in")
        return token
    }
}

//
//  FirebasePhoneAuth.swift
//  Voiid
//
//  Firebase Phone Auth (OTP) — the OTP is sent + verified by Firebase on-device;
//  we then exchange the resulting Firebase ID token for OUR JWT (see AuthService).
//
//  Flow:
//    1. sendCode(e164)            -> verificationID (Firebase texts the user)
//    2. verify(verificationID, code) -> Firebase ID token (then AuthService.loginWithFirebase)
//
//  Requires FirebaseApp.configure() at launch + GoogleService-Info.plist in the
//  target, and (for real devices) an APNs key uploaded to Firebase, plus the
//  Phone provider enabled in the Firebase Console.
//

import Foundation
import FirebaseAuth

enum FirebasePhoneAuth {
    /// The verified E.164 phone of the currently signed-in Firebase user, if any.
    /// Firebase persists the signed-in user across launches, so this recovers the real
    /// number even for sessions created before we started saving it at OTP time — the
    /// server never stores the number, so this (or the OTP capture) is the only source.
    static var currentPhoneNumber: String? {
        let n = Auth.auth().currentUser?.phoneNumber
        return (n?.isEmpty == false) ? n : nil
    }

    /// Unwrap a FirebaseAuth error into something a human can act on.
    ///
    /// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────
    /// `localizedDescription` on an auth failure is very often the string "An internal error
    /// has occurred", which names no cause and points at nothing. The actual reason is always
    /// present but nested: the AuthErrorCode is on the outer error, and the server's own
    /// message is buried in `userInfo[NSUnderlyingErrorKey]` — usually as a JSON body under
    /// `FIRAuthErrorUserInfoDeserializedResponseKey`.
    ///
    /// So this logs the whole chain and returns a description that says which of the handful
    /// of real causes it is. Every one of those causes is a CONSOLE OR PROJECT
    /// MISCONFIGURATION rather than anything the user did, which is exactly why the opaque
    /// default is so expensive to debug.
    private static func describe(_ error: Error, phase: String) -> String {
        let ns = error as NSError
        print("[VOIID][FirebaseAuth] ❌ \(phase) failed")
        print("[VOIID][FirebaseAuth]    domain=\(ns.domain) code=\(ns.code)")
        print("[VOIID][FirebaseAuth]    localized=\(ns.localizedDescription)")

        if let code = AuthErrorCode(rawValue: ns.code) {
            print("[VOIID][FirebaseAuth]    AuthErrorCode=\(code)")
        }
        for (key, value) in ns.userInfo {
            print("[VOIID][FirebaseAuth]    userInfo[\(key)] = \(value)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            print("[VOIID][FirebaseAuth]    underlying domain=\(underlying.domain) code=\(underlying.code)")
            for (key, value) in underlying.userInfo {
                print("[VOIID][FirebaseAuth]    underlying[\(key)] = \(value)")
            }
        }

        // Turn the codes that actually occur here into an instruction, not a restatement.
        switch AuthErrorCode(rawValue: ns.code) {
        case .invalidAppCredential:
            return "Firebase rejected this app's credentials. The APNs auth key is missing or "
                 + "wrong in the Firebase console, or this build's bundle id / team does not "
                 + "match the registered iOS app."
        case .missingAppToken, .notificationNotForwarded:
            return "Firebase could not verify the app via silent push. Upload an APNs key to "
                 + "the Firebase console, and check the Push Notifications capability."
        case .appNotVerified:
            return "App verification failed. Silent APNs verification did not complete and the "
                 + "reCAPTCHA fallback could not run."
        case .quotaExceeded:
            return "SMS quota exceeded for this Firebase project."
        case .invalidPhoneNumber:
            return "That phone number is not in a valid format."
        case .tooManyRequests:
            return "Too many attempts from this device. Wait a while before trying again."
        case .captchaCheckFailed:
            return "reCAPTCHA verification failed — check the custom URL scheme in Info.plist."
        default:
            // Still better than the raw string: it carries the code, which is searchable.
            return "\(ns.localizedDescription) (code \(ns.code))"
        }
    }

    /// A failure carrying the unwrapped explanation, so the UI can show something useful.
    struct AuthFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Start verification: Firebase sends the SMS and returns a verification ID.
    static func sendCode(to e164: String) async throws -> String {
        print("[VOIID][FirebaseAuth] sendCode → \(e164)")
        return try await withCheckedThrowingContinuation { cont in
            PhoneAuthProvider.provider().verifyPhoneNumber(e164, uiDelegate: nil) { verificationID, error in
                if let error {
                    let message = describe(error, phase: "sendCode(\(e164))")
                    cont.resume(throwing: AuthFailure(message: message))
                    return
                }
                guard let verificationID else {
                    cont.resume(throwing: NSError(domain: "voiid.firebase", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No verification ID"]))
                    return
                }
                cont.resume(returning: verificationID)
            }
        }
    }

    /// Verify the entered code and return the Firebase ID token for our backend.
    static func verify(verificationID: String, code: String) async throws -> String {
        let credential = PhoneAuthProvider.provider()
            .credential(withVerificationID: verificationID, verificationCode: code)
        do {
            let result = try await Auth.auth().signIn(with: credential)
            return try await result.user.getIDToken()
        } catch {
            throw AuthFailure(message: describe(error, phase: "verify"))
        }
    }
}

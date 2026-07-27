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

    /// Start verification: Firebase sends the SMS and returns a verification ID.
    static func sendCode(to e164: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            PhoneAuthProvider.provider().verifyPhoneNumber(e164, uiDelegate: nil) { verificationID, error in
                if let error { cont.resume(throwing: error); return }
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
        let result = try await Auth.auth().signIn(with: credential)
        return try await result.user.getIDToken()
    }
}

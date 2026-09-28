//
//  VPinProof.swift
//  Voiid
//
//  The V PIN proof: what this phone sends the server INSTEAD of the PIN.
//
//  The server checks it and counts every wrong one — 5 wrong, and the PIN locks for 24
//  hours (backend/api/src/vpin.ts, which is the source of truth for this recipe). The PIN
//  itself never leaves the phone:
//
//      proof = PBKDF2-HMAC-SHA256(password: pin (UTF-8),
//                                 salt:     "voiid.vpin.auth.v1:" + authSalt (16 bytes),
//                                 rounds:   600,000,
//                                 length:   32 bytes)
//
//  ── THIS MUST MATCH ANDROID AND THE SERVER, BYTE FOR BYTE ─────────────────────────────
//  A PIN set on an iPhone is unlocked from whatever phone the person has next. If the
//  three implementations drift by a single byte, that restore fails with "wrong PIN" and
//  nothing else. `knownAnswerHolds` pins the same vector as backend test/vpin.test.ts and
//  Android VPinProof.kt; the debug build asserts it at first use.
//

import CommonCrypto
import Foundation

enum VPinProof {
    static let saltPrefix = "voiid.vpin.auth.v1:"
    static let rounds: UInt32 = 600_000
    static let length = 32
    static let authSaltLength = 16

    /// A fresh random salt for a new V PIN.
    static func newAuthSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: authSaltLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, authSaltLength, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    /// The proof for `pin` over `authSalt`. ~0.3–0.6s on a phone: slow on purpose.
    static func proof(pin: String, authSalt: Data) -> Data {
        #if DEBUG
        assert(knownAnswerHolds, "VPinProof no longer matches the server and Android")
        #endif
        return proof(pinUnchecked: pin, authSalt: authSalt)
    }

    /// The shared known answer: pin 24681357, salt 00 01 … 0f.
    static let knownAnswerHolds: Bool = {
        let salt = Data((0..<16).map { UInt8($0) })
        return proof(pinUnchecked: "24681357", authSalt: salt).base64EncodedString()
            == "+UVIgV0f50UAMTdE4+wxE22X62xIZX1Gxyos9o1wzyA="
    }()

    /// The derivation without the self-check, so the check itself can call it.
    private static func proof(pinUnchecked pin: String, authSalt: Data) -> Data {
        let password = Array(pin.utf8)
        let salt = Array(saltPrefix.utf8) + Array(authSalt)
        var out = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                password.count, salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, length)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return Data(out)
    }
}

//
//  FXZip.swift
//  Voiid
//
//  Reading .voiidfx packs.
//
//  Foundation-only on purpose: no Metal, no UIKit. The pack format is the one
//  place a malformed or hostile file reaches the app, so it is the part most
//  worth testing, and keeping it dependency-free means it can be tested on the
//  host against real packs rather than only on a device.
//

import Foundation
import CryptoKit

enum FXAssetError: Error, CustomStringConvertible {
    case packUnreadable(String)
    case manifestMissing(String)
    case atlasDecodeFailed(String)
    case integrityMismatch(String)
    case unsafeEntry(String)
    case tooLarge(String)

    var description: String {
        switch self {
        case .packUnreadable(let id):    return "pack '\(id)' could not be read"
        case .manifestMissing(let id):   return "pack '\(id)' has no manifest.json"
        case .atlasDecodeFailed(let id): return "pack '\(id)': atlas failed to decode"
        case .integrityMismatch(let id): return "pack '\(id)': sha256 did not match the index"
        case .unsafeEntry(let n):        return "refusing pack entry '\(n)'"
        case .tooLarge(let id):          return "pack '\(id)' exceeds the size cap"
        }
    }
}

// MARK: - Minimal zip reader
//
// Packs are written STORED, so reading one is locating the central directory
// and slicing. Pulling in a zip library to slice uncompressed bytes would be a
// dependency for nothing.

enum FXZip {
    static func entries(in data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard bytes.count > 22 else { throw FXAssetError.packUnreadable("<zip>") }

        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int {
            Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }

        // End-of-central-directory: scan back for its signature.
        var eocd = -1
        var i = bytes.count - 22
        while i >= 0 {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw FXAssetError.packUnreadable("<zip>") }

        let count = u16(eocd + 10)
        var offset = u32(eocd + 16)
        var out: [String: Data] = [:]

        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(offset) == 0x02014b50 else { break }
            let method = u16(offset + 10)
            let compressed = u32(offset + 20)
            let nameLen = u16(offset + 28)
            let extraLen = u16(offset + 30)
            let commentLen = u16(offset + 32)
            let localOffset = u32(offset + 42)

            guard offset + 46 + nameLen <= bytes.count,
                  let name = String(bytes: bytes[(offset + 46)..<(offset + 46 + nameLen)],
                                    encoding: .utf8) else { break }

            if method == 0, localOffset + 30 <= bytes.count, u32(localOffset) == 0x04034b50 {
                let lNameLen = u16(localOffset + 26)
                let lExtraLen = u16(localOffset + 28)
                let start = localOffset + 30 + lNameLen + lExtraLen
                let end = start + compressed
                if end <= bytes.count {
                    out[name] = Data(bytes[start..<end])
                }
            }
            offset += 46 + nameLen + extraLen + commentLen
        }
        return out
    }
}

enum FXIntegrity {
    /// A downloaded pack is verified against the CDN index before it is
    /// unpacked, so a corrupted or substituted file is rejected rather than
    /// parsed.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}


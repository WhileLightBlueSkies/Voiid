//
//  CallSDPTuning.swift
//  Voiid
//
//  Small, defensive SDP rewrites applied to every local description before it
//  is set — offers, answers, and ICE-restart offers alike.
//
//  Right now that means turning on two Opus features that WebRTC leaves off by
//  default and that matter a lot on real mobile networks:
//
//    useinbandfec=1 — Opus carries a low-bitrate copy of the previous frame
//                     inside the current one, so a single lost packet is
//                     reconstructed instead of becoming a gap. This is the
//                     single highest-value knob for cellular packet loss.
//    usedtx=1       — discontinuous transmission: stop sending during silence.
//                     Cuts bandwidth (and therefore loss under congestion) and
//                     saves battery on a metered link.
//
//  Deliberately NOT set: `maxaveragebitrate`, `stereo`, or any `b=AS:` line.
//  Capping the bitrate here would fight WebRTC's congestion controller, which is
//  what actually adapts the call to a degrading link. Leaving it alone keeps
//  adaptive bitrate fully in charge.
//
//  Every function is total: if the SDP doesn't look the way we expect, it is
//  returned untouched. A munge failure must never cost us a call.
//

import Foundation

enum CallSDPTuning {

    /// Apply all local-description tuning. Safe to call on any SDP.
    static func tuneLocalDescription(_ sdp: String) -> String {
        enableOpusFECAndDTX(in: sdp)
    }

    /// Ensure the Opus `a=fmtp:` line carries `useinbandfec=1;usedtx=1`,
    /// adding the line if the payload was negotiated without one.
    static func enableOpusFECAndDTX(in sdp: String) -> String {
        // Normalise on \n for processing but remember the original line ending —
        // SDP is canonically CRLF and some stacks are strict about it.
        let usesCRLF = sdp.contains("\r\n")
        var lines = sdp.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        // Find every Opus payload type. There can legitimately be more than one
        // (e.g. different clock rates), so handle them all.
        var opusPayloads: [String] = []
        for line in lines where line.hasPrefix("a=rtpmap:") {
            // a=rtpmap:111 opus/48000/2
            let body = line.dropFirst("a=rtpmap:".count)
            guard let space = body.firstIndex(of: " ") else { continue }
            let payload = String(body[body.startIndex..<space])
            let codec = body[body.index(after: space)...].lowercased()
            if codec.hasPrefix("opus/") { opusPayloads.append(payload) }
        }
        guard !opusPayloads.isEmpty else { return sdp }   // no Opus — leave it alone

        let wanted = ["useinbandfec": "1", "usedtx": "1"]

        for payload in opusPayloads {
            let fmtpPrefix = "a=fmtp:\(payload) "
            if let idx = lines.firstIndex(where: { $0.hasPrefix(fmtpPrefix) }) {
                lines[idx] = merge(params: wanted, intoFmtpLine: lines[idx], prefix: fmtpPrefix)
            } else if let rtpmapIdx = lines.firstIndex(where: { $0.hasPrefix("a=rtpmap:\(payload) ") }) {
                // No fmtp line for this payload: synthesise one directly after
                // the rtpmap it belongs to.
                let params = wanted.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
                lines.insert("a=fmtp:\(payload) \(params)", at: rtpmapIdx + 1)
            }
        }

        let joined = lines.joined(separator: "\n")
        return usesCRLF ? joined.replacingOccurrences(of: "\n", with: "\r\n") : joined
    }

    /// Merge key=value params into an existing fmtp line without disturbing the
    /// params already there (order preserved, existing values overwritten).
    private static func merge(params: [String: String], intoFmtpLine line: String, prefix: String) -> String {
        let existing = String(line.dropFirst(prefix.count))
        var pairs: [(String, String)] = []
        var seen = Set<String>()

        for chunk in existing.components(separatedBy: ";") {
            let trimmed = chunk.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let eq = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eq])
                let value = String(trimmed[trimmed.index(after: eq)...])
                seen.insert(key)
                pairs.append((key, params[key] ?? value))
            } else {
                // A bare flag with no "=" — keep it verbatim.
                pairs.append((trimmed, ""))
            }
        }
        for (key, value) in params.sorted(by: { $0.key < $1.key }) where !seen.contains(key) {
            pairs.append((key, value))
        }

        let rendered = pairs.map { $0.1.isEmpty ? $0.0 : "\($0.0)=\($0.1)" }.joined(separator: ";")
        return prefix + rendered
    }
}

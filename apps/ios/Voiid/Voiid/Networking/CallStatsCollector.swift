//
//  CallStatsCollector.swift
//  Voiid
//
//  Samples WebRTC's getStats during a connected call to (a) drive a live
//  good/fair/poor quality indicator and (b) build one anonymous aggregate that
//  is POSTed to /calls/metrics when the call ends.
//
//  PRIVACY — THIS IS A HARD BOUNDARY, NOT A GUIDELINE:
//  The only things that ever leave the device are the numeric fields on
//  `CallMetrics`. No SDP. No ICE candidates. No IP addresses — not the local
//  one, not the remote one, not the TURN server's. No peer user id, no display
//  name, no phone number, no conversation id. Not the network interface type
//  (wifi vs cellular is a location/behaviour signal). `call_id` is a per-call
//  random UUID that the backend already knows and that links to nothing after
//  the call record ages out.
//
//  If you add a field here, it must be a number or a bounded enum, and you must
//  be able to say out loud why it cannot identify a person. `relayed` is the
//  furthest we go: a single bool saying whether TURN was needed, which is an
//  infrastructure-capacity fact, not a user fact.
//
//  Everything is best-effort. Stats parsing runs on whatever thread WebRTC hands
//  us and can see fields we don't expect; every read is optional-chained and a
//  failure just produces a nil metric. Telemetry must never end a call.
//

import Foundation
import LiveKitWebRTC

/// Live connection quality, derived from loss + RTT. Drives an optional UI badge.
enum CallQuality: String, Equatable {
    case unknown
    case good
    case fair
    case poor

    /// True when the user should plausibly be warned.
    var isDegraded: Bool { self == .poor || self == .fair }
}

/// Why a call ended. Sent verbatim as `end_reason` — keep these stable, the
/// backend aggregates on them.
enum CallEndReason: String {
    case localHangup = "local_hangup"
    case remoteHangup = "remote_hangup"
    case declined = "declined"
    case busy = "busy"
    case iceFailed = "ice_failed"
    case timeout = "timeout"
    case setupFailed = "setup_failed"
    /// The callee has NO registered devices — signed out, or every device revoked. Distinct
    /// from `timeout`: nobody declined and nobody failed to answer, there was nowhere to
    /// ring. Showing this as "missed" told the caller the wrong thing about the other person.
    case unavailable = "unavailable"
    case unknown = "unknown"
}

/// The anonymous aggregate POSTed on call end. See the privacy note above
/// before adding anything.
struct CallMetrics: Encodable {
    let call_id: String
    let connected: Bool
    /// Time from call start to first `connected` ICE state.
    let setup_ms: Int?
    let duration_ms: Int?
    let end_reason: String
    /// Whether media went through a TURN relay rather than peer-to-peer.
    let relayed: Bool
    let ice_restarts: Int
    let avg_rtt_ms: Double?
    let avg_packet_loss_pct: Double?
    let jitter_ms: Double?
    let platform: String
    /// The first ~30s after media connected, point by point — see `CallTimelinePoint`.
    let early_timeline: [CallTimelinePoint]?
}

/// One point from the first seconds of a call. Timings and loss only, never identity.
///
/// Answers the question the averages could not: when a call is laggy for its first 20
/// seconds, is the delay in the NETWORK (`rtt`) or in this phone's own PLAYOUT BUFFER
/// (`buf`)? The server keeps exactly these five numbers (backend callMetrics.ts).
struct CallTimelinePoint: Encodable {
    /// Seconds since media connected.
    let t: Int
    /// Network round trip, ms.
    let rtt: Double?
    /// How long received audio waited in this phone's playout buffer, ms.
    let buf: Double?
    /// % of the other side's media this phone lost.
    let loss: Double?
    /// % of this phone's media the other side lost.
    let up: Double?
}

/// One parsed getStats sample.
struct CallStatsSample {
    var rttMs: Double?
    var packetLossPct: Double?
    var jitterMs: Double?
    var inboundBitrateKbps: Double?
    var outboundBitrateKbps: Double?
    var framesDecoded: Int?
    var freezeCount: Int?
    var audioLevel: Double?
    /// "host" / "srflx" / "prflx" / "relay" — the local end of the selected pair.
    var candidatePairType: String?
    var relayed: Bool { candidatePairType == "relay" }
    /// How much of the media THIS phone sent the other side never received, as the other
    /// side reports it back over RTCP (remote-inbound-rtp `fractionLost`). The one reading
    /// that points at this phone's own uplink rather than the other person's — which is
    /// what decides whether "Your network is weak" is true for the person seeing it.
    var uplinkLossPct: Double?
    /// How long received audio waited in the playout buffer over the last interval, ms.
    /// High here with a low `rttMs` means the delay is inside this phone, not the network.
    var playoutBufferMs: Double?
}

@MainActor
final class CallStatsCollector {

    /// Latest parsed sample, for a debug/quality UI.
    private(set) var latest: CallStatsSample?
    /// Live quality signal. CallService republishes this.
    private(set) var quality: CallQuality = .unknown

    /// Fired on every sample so CallService can republish quality without polling.
    var onUpdate: ((CallQuality, CallStatsSample) -> Void)?

    // Running aggregates for the end-of-call POST.
    private var rttSum = 0.0, rttCount = 0
    private var lossSum = 0.0, lossCount = 0
    private var jitterSum = 0.0, jitterCount = 0
    private(set) var everRelayed = false

    // Cumulative counters from the previous sample, for delta-based rates.
    private var lastBytesReceived: Int64?
    private var lastBytesSent: Int64?
    private var lastPacketsLost: Int64?
    private var lastPacketsReceived: Int64?
    private var lastSampleAt: Date?

    private var timer: Timer?
    private weak var pc: LKRTCPeerConnection?

    private static let sampleInterval: TimeInterval = 3.0

    /// Begin sampling. Idempotent — restarts cleanly if called again.
    func start(pc: LKRTCPeerConnection) {
        stop()
        self.pc = pc
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pc = nil
    }

    /// Drop the rate baselines so the first sample after an ICE restart doesn't
    /// report a nonsense bitrate spike across the reconnect gap. Aggregates are
    /// intentionally kept — they describe the whole call.
    func resetRateBaseline() {
        lastBytesReceived = nil
        lastBytesSent = nil
        lastPacketsLost = nil
        lastPacketsReceived = nil
        lastJbDelaySec = nil
        lastJbEmitted = nil
        lastSampleAt = nil
    }

    private func sample() {
        guard let pc else { return }
        pc.statistics { [weak self] report in
            #if DEBUG
            for stat in report.statistics.values where ["inbound-rtp", "outbound-rtp", "media-source"].contains(stat.type) {
                guard (stat.values["kind"] as? String ?? stat.values["mediaType"] as? String) == "audio" else { continue }
                let fields = ["packetsSent", "packetsReceived", "bytesSent", "bytesReceived", "totalAudioEnergy", "audioLevel", "totalSamplesReceived", "concealedSamples"].compactMap { key -> String? in
                    guard let value = stat.values[key] as? NSNumber else { return nil }
                    return "\(key)=\(value)"
                }
                NSLog("[VOIID] call-media: %@ %@", stat.type, fields.joined(separator: " "))
            }
            #endif
            // WebRTC calls back on its own signaling thread; parse there (it's
            // pure) and hop to main to publish.
            let parsed = CallStatsCollector.parse(report)
            Task { @MainActor in self?.ingest(parsed) }
        }
    }

    // MARK: - Parsing

    /// Pull the fields we care about out of the standard stats report. Returns a
    /// raw snapshot of *cumulative* counters; `ingest` converts them to rates.
    private nonisolated static func parse(_ report: LKRTCStatisticsReport) -> RawStats {
        var raw = RawStats()
        let stats = report.statistics

        // 1. Selected candidate pair -> RTT + whether we're relayed.
        //    Prefer the transport's explicit pointer; fall back to a nominated
        //    succeeded pair, which is what older stats builds expose.
        var selectedPairId: String?
        for (_, s) in stats where s.type == "transport" {
            if let id = s.values["selectedCandidatePairId"] as? String { selectedPairId = id; break }
        }
        var selectedPair: LKRTCStatistics?
        if let selectedPairId, let pair = stats[selectedPairId] {
            selectedPair = pair
        } else {
            for (_, s) in stats where s.type == "candidate-pair" {
                let nominated = (s.values["nominated"] as? NSNumber)?.boolValue ?? false
                let state = s.values["state"] as? String
                if nominated && state == "succeeded" { selectedPair = s; break }
            }
        }
        if let pair = selectedPair {
            if let rtt = (pair.values["currentRoundTripTime"] as? NSNumber)?.doubleValue {
                raw.rttMs = rtt * 1000.0
            }
            // Resolve the local candidate to learn host / srflx / relay. We read
            // ONLY `candidateType` — never the address or port.
            if let localId = pair.values["localCandidateId"] as? String,
               let local = stats[localId],
               let type = local.values["candidateType"] as? String {
                raw.candidatePairType = type
            }
            if raw.candidatePairType == nil,
               let remoteId = pair.values["remoteCandidateId"] as? String,
               let remote = stats[remoteId],
               let type = remote.values["candidateType"] as? String {
                raw.candidatePairType = type
            }
        }

        // 2. Inbound RTP: loss, jitter, bytes, video health.
        for (_, s) in stats where s.type == "inbound-rtp" {
            let kind = (s.values["kind"] as? String) ?? (s.values["mediaType"] as? String)
            if let bytes = (s.values["bytesReceived"] as? NSNumber)?.int64Value {
                raw.bytesReceived += bytes
            }
            if let lost = (s.values["packetsLost"] as? NSNumber)?.int64Value {
                raw.packetsLost += max(0, lost)
            }
            if let received = (s.values["packetsReceived"] as? NSNumber)?.int64Value {
                raw.packetsReceived += received
            }
            if kind == "audio" {
                // Cumulative: total seconds samples spent in the jitter buffer, and how many
                // samples left it. Their deltas give the buffer delay for the interval.
                if let d = (s.values["jitterBufferDelay"] as? NSNumber)?.doubleValue { raw.jbDelaySec += d }
                if let n = (s.values["jitterBufferEmittedCount"] as? NSNumber)?.doubleValue { raw.jbEmitted += n }
                if let jitter = (s.values["jitter"] as? NSNumber)?.doubleValue {
                    // Reported in seconds by the spec.
                    raw.jitterMs = (raw.jitterMs ?? 0) + jitter * 1000.0
                    raw.jitterSamples += 1
                }
                if let level = (s.values["audioLevel"] as? NSNumber)?.doubleValue {
                    raw.audioLevel = level
                }
            } else if kind == "video" {
                if let decoded = (s.values["framesDecoded"] as? NSNumber)?.intValue {
                    raw.framesDecoded = decoded
                }
                if let freezes = (s.values["freezeCount"] as? NSNumber)?.intValue {
                    raw.freezeCount = freezes
                }
            }
        }

        // 3. Outbound RTP: bytes for the send-side bitrate.
        for (_, s) in stats where s.type == "outbound-rtp" {
            if let bytes = (s.values["bytesSent"] as? NSNumber)?.int64Value {
                raw.bytesSent += bytes
            }
        }

        // 4. The remote-inbound report: the OTHER side's view of what we sent. Its RTT is the
        //    fallback when the pair had none; its fractionLost is our uplink loss. Audio's is
        //    preferred — it is the stream the call cannot do without, and video loss runs
        //    higher by design (it backs off), so it would cry wolf.
        var audioUplink: Double?, anyUplink: Double?
        for (_, s) in stats where s.type == "remote-inbound-rtp" {
            if raw.rttMs == nil, let rtt = (s.values["roundTripTime"] as? NSNumber)?.doubleValue {
                raw.rttMs = rtt * 1000.0
            }
            if let lost = (s.values["fractionLost"] as? NSNumber)?.doubleValue {
                let pct = max(0, min(1, lost)) * 100.0
                if (s.values["kind"] as? String) == "audio" { audioUplink = max(audioUplink ?? 0, pct) }
                anyUplink = max(anyUplink ?? 0, pct)
            }
        }
        raw.uplinkLossPct = audioUplink ?? anyUplink

        return raw
    }

    /// Cumulative counters straight off a stats report.
    struct RawStats {
        var rttMs: Double?
        var uplinkLossPct: Double?
        var jbDelaySec: Double = 0
        var jbEmitted: Double = 0
        var jitterMs: Double?
        var jitterSamples = 0
        var audioLevel: Double?
        var candidatePairType: String?
        var bytesReceived: Int64 = 0
        var bytesSent: Int64 = 0
        var packetsLost: Int64 = 0
        var packetsReceived: Int64 = 0
        var framesDecoded: Int?
        var freezeCount: Int?
    }

    // MARK: - Ingest

    private func ingest(_ raw: RawStats) {
        let now = Date()
        var sample = CallStatsSample()

        sample.rttMs = raw.rttMs
        sample.jitterMs = raw.jitterSamples > 0 ? (raw.jitterMs ?? 0) / Double(raw.jitterSamples) : nil
        sample.audioLevel = raw.audioLevel
        sample.candidatePairType = raw.candidatePairType
        sample.uplinkLossPct = raw.uplinkLossPct
        sample.framesDecoded = raw.framesDecoded
        sample.freezeCount = raw.freezeCount

        // Rates need two samples; the first one only establishes the baseline.
        if let lastAt = lastSampleAt {
            let elapsed = now.timeIntervalSince(lastAt)
            if elapsed > 0.1 {
                if let prev = lastBytesReceived, raw.bytesReceived >= prev {
                    sample.inboundBitrateKbps = Double(raw.bytesReceived - prev) * 8.0 / elapsed / 1000.0
                }
                if let prev = lastBytesSent, raw.bytesSent >= prev {
                    sample.outboundBitrateKbps = Double(raw.bytesSent - prev) * 8.0 / elapsed / 1000.0
                }
            }
            if let prevDelay = lastJbDelaySec, let prevEmitted = lastJbEmitted {
                let dEmitted = raw.jbEmitted - prevEmitted
                if dEmitted > 0 {
                    sample.playoutBufferMs = max(0, raw.jbDelaySec - prevDelay) / dEmitted * 1000.0
                }
            }
            // Interval loss %, not lifetime — a bad patch shouldn't be diluted
            // by an otherwise clean call, that's what the average is for.
            if let prevLost = lastPacketsLost, let prevRecv = lastPacketsReceived {
                let dLost = max(0, raw.packetsLost - prevLost)
                let dRecv = max(0, raw.packetsReceived - prevRecv)
                let total = dLost + dRecv
                if total > 0 { sample.packetLossPct = Double(dLost) / Double(total) * 100.0 }
            }
        }

        lastBytesReceived = raw.bytesReceived
        lastBytesSent = raw.bytesSent
        lastPacketsLost = raw.packetsLost
        lastPacketsReceived = raw.packetsReceived
        lastJbDelaySec = raw.jbDelaySec
        lastJbEmitted = raw.jbEmitted
        lastSampleAt = now
        recordTimelinePoint(sample, at: now)

        // Accumulate for the end-of-call aggregate.
        if let rtt = sample.rttMs { rttSum += rtt; rttCount += 1 }
        if let loss = sample.packetLossPct { lossSum += loss; lossCount += 1 }
        if let jitter = sample.jitterMs { jitterSum += jitter; jitterCount += 1 }
        if sample.relayed { everRelayed = true }

        latest = sample
        quality = Self.quality(for: sample)
        updateOwnNetwork(sample)
        onUpdate?(quality, sample)
    }

    // MARK: - The first seconds

    private var lastJbDelaySec: Double?
    private var lastJbEmitted: Double?
    /// When media first connected; the timeline counts from here. Nil until then.
    private var mediaConnectedAt: Date?
    private(set) var timeline: [CallTimelinePoint] = []
    /// Up to ~30s, at most 12 points — the server's cap.
    private static let timelineSeconds = 31.0
    private static let timelineMaxPoints = 12

    /// Called once, when media first flows. Later calls (a reconnect) do not move the start.
    func markMediaConnected(at date: Date = Date()) {
        if mediaConnectedAt == nil { mediaConnectedAt = date }
    }

    private func recordTimelinePoint(_ s: CallStatsSample, at now: Date) {
        guard let start = mediaConnectedAt, timeline.count < Self.timelineMaxPoints else { return }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 0, elapsed <= Self.timelineSeconds else { return }
        timeline.append(CallTimelinePoint(
            t: Int(elapsed.rounded()),
            rtt: Self.round2(s.rttMs), buf: Self.round2(s.playoutBufferMs),
            loss: Self.round2(s.packetLossPct), up: Self.round2(s.uplinkLossPct)))
    }

    // MARK: - "Your network is weak"

    /// Whether THIS phone's connection is the weak one — shown only to its own user. The rule
    /// and the no-flicker hold live in CallNetworkVerdict.swift, where they are tested.
    private var weakTracker = WeakNetworkTracker()
    var ownNetworkWeak: Bool { weakTracker.isWeak }

    private func updateOwnNetwork(_ sample: CallStatsSample) {
        weakTracker.record(CallNetworkVerdict.ownSideLooksWeak(
            uplinkLossPct: sample.uplinkLossPct, downlinkLossPct: sample.packetLossPct, rttMs: sample.rttMs))
    }

    /// Loss dominates perceived quality on voice; RTT matters for interactivity.
    /// Thresholds are the conventional VoIP ones (ITU G.114 puts 150ms one-way /
    /// ~300ms round-trip at the edge of comfortable conversation).
    private static func quality(for s: CallStatsSample) -> CallQuality {
        let loss = s.packetLossPct
        let rtt = s.rttMs
        if loss == nil && rtt == nil { return .unknown }
        if (loss ?? 0) >= 8 || (rtt ?? 0) >= 500 { return .poor }
        if (loss ?? 0) >= 3 || (rtt ?? 0) >= 250 { return .fair }
        return .good
    }

    // MARK: - Aggregate

    var avgRttMs: Double? { rttCount > 0 ? rttSum / Double(rttCount) : nil }
    var avgPacketLossPct: Double? { lossCount > 0 ? lossSum / Double(lossCount) : nil }
    var avgJitterMs: Double? { jitterCount > 0 ? jitterSum / Double(jitterCount) : nil }

    /// Round to keep the payload tidy and to avoid shipping spurious precision.
    private static func round2(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return (v * 100).rounded() / 100
    }

    func buildMetrics(callId: String,
                      connected: Bool,
                      setupMs: Int?,
                      durationMs: Int?,
                      endReason: CallEndReason,
                      iceRestarts: Int) -> CallMetrics {
        CallMetrics(
            call_id: callId,
            connected: connected,
            setup_ms: setupMs,
            duration_ms: durationMs,
            end_reason: endReason.rawValue,
            relayed: everRelayed,
            ice_restarts: iceRestarts,
            avg_rtt_ms: Self.round2(avgRttMs),
            avg_packet_loss_pct: Self.round2(avgPacketLossPct),
            jitter_ms: Self.round2(avgJitterMs),
            platform: "ios",
            early_timeline: timeline.isEmpty ? nil : timeline
        )
    }

    /// Wipe all accumulated state between calls.
    func reset() {
        stop()
        latest = nil
        quality = .unknown
        weakTracker.reset()
        mediaConnectedAt = nil
        timeline = []
        rttSum = 0; rttCount = 0
        lossSum = 0; lossCount = 0
        jitterSum = 0; jitterCount = 0
        everRelayed = false
        resetRateBaseline()
    }
}

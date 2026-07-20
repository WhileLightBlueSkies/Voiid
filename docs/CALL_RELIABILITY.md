# VOIID — call reliability: getting to WhatsApp-grade in all environments

> **Target:** a VOIID call should connect and stay up as reliably as a WhatsApp
> or PSTN call — on home WiFi, on cellular, on hotel/corporate/captive networks,
> behind CGNAT, and while the user physically moves between networks.
>
> This doc is the gap list between "calls work in a demo" and that bar. Items are
> ordered by real-world impact.
>
> Last updated: 2026-07-20

---

## Where we are

**Built + build-verified:** WebRTC 1:1 voice/video on both platforms (unified
plan, DTLS-SRTP media, trickle ICE, continual gathering), server-authenticated
signaling relay, `GET /calls/turn` credential issuance, call records, ring push.

**In flight:** coturn deployment config + TURN env, iOS PushKit VoIP ringing,
LiveKit token issuance for group calls.

**Not built — this document.**

---

## P0 — the failures users actually hit

### 1. Network handover (WiFi ↔ cellular) — ICE restart
**Symptom:** user walks out of the house mid-call, call dies.
This is the single most common real-world call failure and the most visible
difference vs WhatsApp.

- [ ] Detect network path changes: iOS `NWPathMonitor`, Android
      `ConnectivityManager.NetworkCallback`.
- [ ] On change (and on `RTCIceConnectionState.disconnected`/`failed`), perform an
      **ICE restart**: create a new offer with `iceRestart: true`, send it over the
      existing signaling channel, renegotiate. Do NOT tear down the call.
- [ ] Handle the answerer side: accept a re-offer for an in-progress call
      (`call_offer` for a `call_id` we already have → renegotiate, don't ring again).
- [ ] Backoff + cap: N restart attempts, then end with a clear "call lost" state.
- [ ] `disconnected` is often transient — wait a grace period (~2–5s) before acting;
      only `failed` is terminal.

### 2. Mid-call signaling reconnection
**Symptom:** socket drops (backgrounding, flaky network) → no ICE/hangup can flow.
- [ ] Auto-reconnect the WebSocket with exponential backoff while a call is active.
- [ ] Queue outbound signaling (ICE candidates especially) while disconnected and
      flush on reconnect.
- [ ] Media (SRTP) can survive a signaling drop — never end a connected call just
      because the socket blipped.

### 3. TURN coverage and placement
**Symptom:** call connects but is laggy/choppy, or fails on restrictive networks.
- [ ] **Multi-region TURN** — relays near users (a single distant relay adds 150ms+
      each way). At minimum: one per major user region.
- [ ] Every relay must offer **UDP 3478, TCP 3478, TLS 5349, and TLS 443**. 443 is
      what gets through hotel/corporate/captive networks.
- [ ] Verify the ICE server list returned by `GET /calls/turn` actually includes the
      TCP/TLS/443 variants, not just UDP.
- [ ] Monitor relay health; drop unhealthy relays out of issuance.

### 4. Audio session + processing correctness
**Symptom:** echo, clipping, one-way audio, wrong output device. Users read this as
"the app is broken" even when the call connected fine.
- [ ] iOS: `AVAudioSession` category `.playAndRecord`, mode **`.voiceChat`**, with
      CallKit driving activation (`RTCAudioSession` manual audio — we already use
      manual audio; verify the mode/category and the CallKit `didActivate` handoff).
- [ ] Android: `AudioManager` **`MODE_IN_COMMUNICATION`**, correct
      speaker/earpiece/bluetooth routing, and restore the prior mode on end.
- [ ] Confirm WebRTC's APM is on: **AEC, noise suppression, AGC**; prefer hardware
      AEC where the device provides it.
- [ ] Bluetooth/headset route changes mid-call handled (route-change notifications).

### 5. Codec resilience under loss
- [ ] Opus **FEC + DTX + PLC** enabled for audio (survives packet loss far better).
- [ ] Video: adaptive bitrate (WebRTC GCC/transport-cc) verified on; consider
      simulcast when group calls land.
- [ ] Prefer hardware codecs where available (battery + thermal).

---

## P1 — you can't claim reliability you don't measure

### 6. Call quality telemetry
**We currently have zero visibility into call success/quality.** This must exist
before "WhatsApp-grade" is a claim rather than a hope.
- [ ] Sample `RTCPeerConnection.getStats()` during calls: packet loss, jitter, RTT,
      bitrate, freeze count, audio level, selected candidate-pair type
      (host/srflx/**relay**).
- [ ] Aggregate per-call outcome: connected? time-to-connect? end reason? relayed?
      Report **anonymously/aggregated only** — no call content, no peer identifiers;
      this is a privacy product.
- [ ] Track the headline metrics: **call setup success rate**, **median
      time-to-connect**, **drop rate**, **% relayed via TURN**. These are the numbers
      that tell you if you're at parity.
- [ ] Alert on regressions.

### 7. Connection speed
- [ ] Pre-fetch ICE servers (cache `GET /calls/turn`) so call setup isn't gated on
      an HTTP round trip.
- [ ] Start gathering candidates as early as possible on the callee side.
- [ ] Target < ~2s time-to-connect on a normal network.

---

## P2 — hardening

- [ ] **Call end-reason taxonomy** (declined / busy / timeout / network-failed /
      remote-hangup) so the UI can say something true.
- [ ] **Ring timeout** → missed-call record on both sides (partially handled).
- [ ] **Concurrent-call handling** (busy signal) — implemented; verify both platforms.
- [ ] **Battery/thermal**: stop video capture when backgrounded, lower resolution
      under thermal pressure.
- [ ] **Permission edge cases**: mic/camera denied mid-call, another app holding the
      mic, phone call interrupting a VOIID call (`AVAudioSession` interruptions).

---

## Verification plan (cannot be done in CI — needs real devices)

A build that compiles proves none of this. The matrix that actually validates it:

| Scenario | Expect |
|---|---|
| Both on same WiFi | P2P (host/srflx), connects < 2s |
| Cellular ↔ WiFi | connects, likely srflx or relay |
| Behind symmetric NAT / CGNAT | **relay** via TURN, connects |
| Corporate/hotel firewall (UDP blocked) | **TURN over TLS 443**, connects |
| **Walk WiFi → cellular mid-call** | **call survives** via ICE restart |
| App killed, incoming call | rings via **VoIP push** + CallKit |
| Poor network (5% loss) | audio stays intelligible (Opus FEC/PLC) |
| Bluetooth headset connect/disconnect mid-call | route follows, no dead audio |
| Incoming PSTN call during a VOIID call | handled, audio restored after |

Track: setup success rate, time-to-connect, drop rate, % relayed.

---

## Honest assessment

TURN + PushKit (in flight) removes the two hardest blockers. **ICE restart on
network change (P0 #1) is the next-biggest single win** — without it, any call
where the user moves between networks drops, which is a very common everyday case
that WhatsApp handles invisibly.

Everything above is standard, well-understood WebRTC engineering — no research
required — but it is real work, and the telemetry (P1 #6) is what converts
"we think it's reliable" into a number you can defend.

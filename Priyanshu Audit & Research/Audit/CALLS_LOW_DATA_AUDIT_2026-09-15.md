# Calls on low-data networks: audit and optimization plan

> **Date:** 15 Sep 2026
> **Baseline:** `main` at `9fc79f3`
> **Scope:** 1:1 voice and video, group calls, conference (add-a-person) calls, ringing and call notifications, signaling, TURN and SFU infrastructure, on iOS, Android and the backend.
> **Question:** does a call connect, stay up and stay usable when the connection is slow, lossy or unstable, anywhere in the world?
> **Related:** [docs/CALL_AUDIT_2026-09-09.md](../../docs/CALL_AUDIT_2026-09-09.md) covers race conditions and call-state bugs. Those are not repeated here.

---

## Summary

- **Several paths make a weak network worse.** A failed TURN refresh removes the relay from a live call (both platforms). Android blocks its WebRTC thread on an HTTP request for up to 60 s. Reconnect gives up after roughly 25–60 s, depending on platform and role.
- **Nothing adapts media to the network.** Video always captures 720p at 30 fps with no bitrate ceiling. There is no audio-only fallback. The quality signal the apps compute is never shown and never acted on.
- **Voice is not packed for thin links.** 20 ms Opus packets plus SRTP plus the frame-encryption trailer put an estimated ~68 kbps on the wire while talking. The same audio can fit in about 25–35 kbps.
- **Ringing has three gaps.** iOS group-call rings over VoIP never work (payload bug). VoIP pushes expire at 30 s while a ring lasts 45–60 s. A callee on a slow connection keeps ringing up to 30 s after the caller hangs up.
- **Group calls run on SDK defaults.** That means a 720p30 camera, no audio-only mode, roster polling every 3 s, and join and key timeouts too tight for slow links. The LiveKit and TURN deployments can't be checked from the repo and look single-region.

**Realistic target.** No calling app works at every speed above 0 kbps: packets have a fixed minimum size, and encryption adds to it. With the changes below, the target is:

- Voice keeps working at about **30 kbps each way**, with up to ~600 ms round-trip time and ~10% packet loss.
- Video steps down, then pauses on its own before audio suffers.
- A call survives a **complete outage of up to 90 s**.

Every number marked *estimate* must be confirmed on devices (§6).

### Evidence labels

| Label | Meaning |
|---|---|
| **Source** | Confirmed by reading the code at the cited lines |
| **SDK** | Confirmed in the WebRTC or LiveKit build this app links: headers, `javap` on the Android jar, SDK sources in the local build caches |
| **Estimate** | Arithmetic from packet sizes; measure before relying on it |
| **Verify** | Lives outside the repo (server config, env); must be checked on the server |

Severity: **P0** drops or blocks calls on weak networks · **P1** major failure or data waste on weak networks · **P2** meaningful improvement · **P3** cleanup.

---

## 1. Findings

| ID | Sev | Area | Issue |
|---|---|---|---|
| [LD-01](#ld-01) | P0 | 1:1 reconnect | A failed TURN refresh replaces the relay with Google STUN on a live call (iOS + Android) |
| [LD-02](#ld-02) | P0 | Android 1:1 | TURN fetch blocks the WebRTC thread for up to 60 s |
| [LD-03](#ld-03) | P0 | 1:1 reconnect | Reconnect gives up after ~25–60 s, differs by platform and role, and uses up attempts while offline |
| [LD-04](#ld-04) | P0 | Notifications | iOS group-call ring over VoIP never works (payload `type` hard-coded) |
| [LD-05](#ld-05) | P1 | 1:1 video | No bitrate or resolution control; capture fixed at 720p30; audio has no priority over video |
| [LD-06](#ld-06) | P1 | 1:1 media | No audio-only fallback; call quality is measured but never shown or used |
| [LD-07](#ld-07) | P1 | 1:1 voice | Voice packets too heavy for thin links (20 ms packets + encryption trailer, no bitrate steps) |
| [LD-08](#ld-08) | P1 | 1:1 reconnect | iOS: only the caller may restart ICE, so the answerer's own network switch causes long silence; platforms follow different rules |
| [LD-09](#ld-09) | P1 | Network detection | Unneeded restarts: no debounce on iOS; Android watches every network instead of the one in use |
| [LD-10](#ld-10) | P1 | Signaling | Send queue can drop the SDP offer or answer while keeping its ICE candidates; no delivery ack |
| [LD-11](#ld-11) | P1 | Notifications | Callee keeps ringing up to 30 s after the caller hangs up |
| [LD-12](#ld-12) | P1 | Notifications | VoIP push expires at 30 s; the ring lasts 45 s (callee) and 60 s (caller) |
| [LD-13](#ld-13) | P1 | Call setup | TURN fetched on every call; iOS answer path and Android caller path wait on it |
| [LD-14](#ld-14) | P1 | Infrastructure | TURN, SFU and API placement can't be verified and look single-region; LiveKit TURN over TLS 443 unknown |
| [LD-15](#ld-15) | P1 | Group calls | LiveKit publishing on SDK defaults (720p30, simulcast, RED); no audio-only or low-data mode |
| [LD-16](#ld-16) | P1 | Group calls | Join (35 s) and key-recovery (8 s) deadlines too tight for slow links |
| [LD-17](#ld-17) | P2 | Signaling | iOS socket backoff grows to 30 s during a call; no ping/pong dead-socket detection |
| [LD-18](#ld-18) | P2 | Infrastructure | Google STUN is the only STUN server (unreachable where Google is blocked) |
| [LD-19](#ld-19) | P2 | Group calls | HTTPS polling during calls: roster every 3 s, presence every 20 s |
| [LD-20](#ld-20) | P2 | Group calls | Group ring waits until the starter has connected to the SFU |
| [LD-21](#ld-21) | P2 | Low-data mode | iOS Low Data Mode and Android Data Saver ignored for calls; no user setting |
| [LD-22](#ld-22) | P2 | Signaling / ICE | Oversized signaling: all-codec SDP, one frame per ICE candidate, no WS compression, TCP host candidates, unpruned TURN connections |
| [LD-23](#ld-23) | P2 | Quality signal | Platforms disagree on "poor"; neither can tell my uplink from theirs |
| [LD-24](#ld-24) | P3 | Telemetry | Metrics can't answer low-data questions |
| [LD-25](#ld-25) | P3 | E2EE | Verification tag sent 3 times even after it arrived |
| [LD-26](#ld-26) | P3 | Docs | `WEBRTC_VERSIONS.md` tracks the wrong WebRTC build for iOS 1:1 |

---

## 2. Findings in detail

<a id="ld-01"></a>
### LD-01 · P0 · A failed TURN refresh removes the relay from a live call

**Evidence:** Source.

**Where**
- iOS falls back to STUN only on any error: [CallService.swift:2459-2474](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2459-L2474). The ICE restart installs that list on the live connection: [CallService.swift:1049-1058](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1049-L1058).
- Android does the same: [CallService.kt:2838-2856](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2838-L2856). It caches the fallback as fresh for 4 minutes: [CallService.kt:2353-2363](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2353-L2363). The restart applies it: [CallService.kt:2438-2443](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2438-L2443).

**On a weak network.** `GET /calls/turn` times out, hits a captive portal or fails DNS, and the client falls back to `[stun:stun.l.google.com:19302]`. During an ICE restart both platforms apply that list with `setConfiguration`, so the restart gathers no relay candidates. Behind CGNAT or a symmetric NAT (common on mobile carriers) peer-to-peer usually fails, so the call can't recover. Android keeps reusing the STUN-only list for 4 minutes. The TURN refresh fails exactly when the network is bad, which is exactly when restarts happen.

**Fix**
1. Keep the last good TURN config with its expiry (server TTL is 3600 s, [turn.ts:12-14](../../backend/api/src/turn.ts#L12-L14)). Never overwrite it with a fallback.
2. On restart, use the cached config at once if it has at least 5 minutes left; refresh in the background.
3. Only call `setConfiguration` with a list that contains at least one `turn:` or `turns:` URL.
4. Use STUN-only only as a last resort for a brand-new call, never as a replacement during a call.

---

<a id="ld-02"></a>
### LD-02 · P0 · Android blocks the WebRTC thread on HTTP for up to 60 s

**Evidence:** Source.

**Where.** `fetchIceServers` uses `runBlocking`: [CallService.kt:2838-2856](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2838-L2856). It runs on the single WebRTC executor `exec`, from four places:
- the caller path: [CallService.kt:454-456](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L454-L456)
- both callee offer paths: [CallService.kt:897-899](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L897-L899) and [CallService.kt:984-986](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L984-L986)
- ICE restart: [CallService.kt:2440-2443](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2440-L2443)

The OkHttp `callTimeout` is 60 s: [ApiClient.kt:122-126](../../apps/android/app/src/main/java/com/voiid/app/net/ApiClient.kt#L122-L126).

**On a weak network.** While the request hangs, everything else queued on `exec` waits:
- applying the peer's ICE candidates
- answering the peer's restart offer
- mute and hold changes
- stats sampling ([CallStats.kt:119-126](../../apps/android/app/src/main/java/com/voiid/app/net/CallStats.kt#L119-L126))
- installing the frame key
- `releaseWebRtc` on hangup

A restart on a flaky network can freeze the call engine for a minute.

**Fix.** Resolve ICE servers on `Dispatchers.IO`, or from the LD-01 cache, *before* posting work to `exec`. Give the TURN request its own 4–5 s timeout. Never block `exec` on I/O.

---

<a id="ld-03"></a>
### LD-03 · P0 · Reconnect gives up too early and inconsistently

**Evidence:** Source (give-up times are approximate sums of the timers).

**Where**
- **iOS caller:** `maxIceRestarts = 3` ([CallService.swift:140](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L140)), with recovery deadlines of 10/20/30 s plus backoff ([CallService.swift:1021-1037](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1021-L1037)).
- **iOS answerer:** ends after 30 s with no retry: [CallService.swift:1014-1019](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1014-L1019), [CallService.swift:1126-1128](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1126-L1128).
- **Android:** `MAX_ICE_RESTARTS = 3` ([CallService.kt:199](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L199)), with 4/8/12 s watchdogs ([CallService.kt:2479-2500](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2479-L2500)).
- **Both:** ICE `disconnected` starts a restart after a 3 s grace, without checking whether any network exists. iOS: [CallService.swift:1132-1150](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1132-L1150). Android: [CallService.kt:2546-2559](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2546-L2559).

**On a weak network.** Approximate give-up times:

| Platform and role | Gives up after |
|---|---|
| iOS caller | ~60 s |
| iOS answerer | 30 s |
| Android, either role | ~25–30 s, plus LD-02 stalls |

Lifts, tunnels, basements and the edge of cell coverage often drop signal for 20–60 s. While offline, each attempt fails its TURN fetch (LD-01), queues an offer nobody receives, and still counts toward the limit. The call is usually already dead when signal returns. Mixed-platform calls end on whichever side quits first.

**Fix**
- Replace the attempt count with one time limit, shared by both platforms and both roles: keep "Reconnecting…" for up to **90 s** (tunable).
- Don't attempt restarts while the OS reports no usable network (iOS `NWPath.status != .satisfied`; Android no default network). Restart once, immediately, when a network returns.
- Back off 2 → 4 → 8 → 15 s between attempts, capped, and reset to 2 s on every network change.
- If it still fails, end with "Call lost: weak connection" and a one-tap redial.

---

<a id="ld-04"></a>
### LD-04 · P0 · iOS group-call rings over VoIP never work

**Evidence:** Source.

**Where**
- The server hard-codes the payload type as `{ aps: {}, type: 'call' }`: [pushPayload.ts:162-173](../../backend/api/src/pushPayload.ts#L162-L173).
- `/calls/group/ring` builds a `type: 'group_call'` meta and sends it through that builder: [calls.ts:513-535](../../backend/api/src/routes/calls.ts#L513-L535).
- iOS only treats a push as a group call if `type == "group_call"`: [VoIPPushManager.swift:156](../../apps/ios/Voiid/Voiid/Networking/VoIPPushManager.swift#L156).
- The group meta has no `call_id`, so iOS generates a random one: [VoIPPushManager.swift:134](../../apps/ios/Voiid/Voiid/Networking/VoIPPushManager.swift#L134).
- No test covers group VoIP payloads; `backend/api/test/conferenceInvitePush.test.ts` covers only 1:1 and conference.

**What happens (on every network).** The iOS member's phone rings in CallKit as a 1:1 call. No SDP offer ever comes, so the ring ends after the 30 s offer timeout ([CallService.swift:1363-1375](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1363-L1375)). If the member taps Answer, the screen stays on "Connecting…" until that timeout. iOS users can't join a group call from the ring.

**Fix.** Set `type: meta?.type === 'group_call' ? 'group_call' : 'call'` in `buildVoipPayload`, and add a payload test for `group_call`. Android is not affected: the FCM data keeps `type` ([pushPayload.ts:89-90](../../backend/api/src/pushPayload.ts#L89-L90)).

---

<a id="ld-05"></a>
### LD-05 · P1 · Video has no bitrate or resolution control, and audio no priority

**Evidence:** Source. SDK support confirmed: both builds expose `maxBitrateBps`, `minBitrateBps`, `maxFramerate`, `scaleResolutionDownBy`, `bitratePriority`, `networkPriority` and `degradationPreference`. iOS: `LiveKitWebRTC.framework/Headers/RTCRtpEncodingParameters.h` and `RTCRtpParameters.h`. Android: `org.webrtc.RtpParameters$Encoding` in stream-webrtc-android 1.3.8.

**Where**
- **iOS:** tracks are added with no encoding parameters ([CallService.swift:2379-2414](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2379-L2414)). Capture picks the format closest to 1280 px wide, at up to 30 fps ([CallService.swift:2416-2452](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2416-L2452)).
- **Android:** same ([CallService.kt:1764-1789](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1764-L1789)), with `startCapture(1280, 720, 30)` ([CallService.kt:1806-1817](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1806-L1817)).

**On a weak network.** WebRTC's congestion control lowers the bitrate, but from a 720p30 source, with no ceiling and no floor for audio. On a 150–400 kbps link, audio and video compete for the same bandwidth estimate: audio breaks up while video turns blocky and freezes. The first 720p keyframes are large and arrive seconds late. The phone also spends CPU and battery encoding 720p it can't send.

**Fix.** Set sender parameters after `addTrack`, and change them during the call with `setParameters` (no renegotiation needed):
- **Audio sender:** `bitratePriority = 4.0`, `networkPriority = high`, `minBitrateBps ≈ 12_000`.
- **Video sender:** `bitratePriority = 1.0`, `networkPriority = low`, `degradationPreference = balanced`. Take `maxBitrateBps`, `scaleResolutionDownBy` and `maxFramerate` from the profile table in §3.2.
- **Capture:** match the profile instead of always 720p30 (iOS `LKRTCVideoSource.adaptOutputFormat(toWidth:height:fps:)`, Android `VideoCapturer.changeCaptureFormat`).
- **Starting point:** start video calls in the *Standard* profile, or *Low* when the OS or the last call says the network is constrained, then step up.

---

<a id="ld-06"></a>
### LD-06 · P1 · No audio-only fallback; call quality is never shown or used

**Evidence:** Source.

**Where**
- **iOS:** quality is computed from loss and RTT ([CallStatsCollector.swift:331-338](../../apps/ios/Voiid/Voiid/Networking/CallStatsCollector.swift#L331-L338)) and published ([CallService.swift:555-564](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L555-L564)).
- **Android:** [CallStats.kt:222-229](../../apps/android/app/src/main/java/com/voiid/app/net/CallStats.kt#L222-L229), exposed as `CallManager.quality`.
- **UI:** neither call screen reads the quality value. The only network state shown is "Reconnecting…" ([CallScreens.swift:169-183](../../apps/ios/Voiid/Voiid/Main/CallScreens.swift#L169-L183), [CallScreens.kt:439-455](../../apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt#L439-L455)).

**On a weak network.** When the link can't carry video, nothing changes. There is no "weak connection" message, no video pause, no downgrade. The user sees frozen video and hears choppy audio with no explanation, and usually hangs up.

**Fix**
- Add a small per-call controller on both platforms (spec in §3.2). It reads stats every 2 s, moves between profiles with hysteresis, turns the video encoding off (`active = false`) below about 150 kbps of available outgoing bitrate, and shows the change in the UI.
- Send a tiny `call_media_hint` frame (for example `{ "video_paused": true, "reason": "network" }`). The other side can then say "Their video is paused: weak connection" instead of showing a frozen frame. Add the frame type to the relay whitelist ([index.ts:768-799](../../backend/websocket/src/index.ts#L768-L799)).

---

<a id="ld-07"></a>
### LD-07 · P1 · Voice packets are too heavy for thin links

**Evidence:** Source, plus an estimate.

**Where**
- SDP tuning adds only `useinbandfec=1;usedtx=1` and deliberately sets no bitrate: [CallSDPTuning.swift:19-22](../../apps/ios/Voiid/Voiid/Networking/CallSDPTuning.swift#L19-L22), [CallSDPTuning.swift:39-74](../../apps/ios/Voiid/Voiid/Networking/CallSDPTuning.swift#L39-L74). Android is the same: [SdpTweaks.kt:27-58](../../apps/android/app/src/main/java/com/voiid/app/net/SdpTweaks.kt#L27-L58).
- Frame encryption is attached to every sender: [CallService.swift:321-353](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L321-L353), [CallService.kt:2121-2159](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2121-L2159).

**Current estimate** (IPv4, while talking, one 20 ms packet):

| Part | Bytes |
|---|---|
| Opus audio at WebRTC's default (~32 kbps) | ~80 |
| RTP header + header extensions | ~12 + ~12 |
| SRTP auth tag | 10 |
| Frame-encryption trailer (16-byte GCM tag, 12-byte IV, 2 index bytes) | ~30 |
| UDP + IPv4 | 28 |
| **Total** | **~172 bytes × 50 packets/s ≈ 68 kbps** |

TURN over TCP/TLS adds more. About half of that is overhead that scales with **packets per second**, not with audio quality. On an EDGE-class or congested link (60–150 kbps, shared both ways) there is no headroom, so loss and audio dropouts follow.

**Optimized estimate:**
- 60 ms packets at 12–16 kbps: ~90–120 bytes + ~92 overhead, × 16.7 packets/s ≈ **24–28 kbps**
- 40 ms packets at 16 kbps: ≈ **34 kbps**

**Fix**
- Turn on `adaptiveAudioPacketTime` on the audio encoding; it is exposed in both builds (same SDK evidence as LD-05). WebRTC then uses longer packets when bandwidth drops. If a build ignores it, set `a=ptime` and `a=maxptime` per profile on renegotiation.
- Set the audio `maxBitrateBps` per profile: 32 → 24 → 16 → 12 kbps. The code comment warns against fighting congestion control; that applies to a fixed cap, not to a cap that follows measured bandwidth.
- Keep FEC and DTX. Don't add RED on thin links; it roughly doubles the audio payload.
- Measure the real packet size on device before and after, from getStats `outbound-rtp`: `bytesSent`, `headerBytesSent` and `packetsSent`. The encryption trailer size above comes from LiveKit's frame format and should be confirmed the same way.

---

<a id="ld-08"></a>
### LD-08 · P1 · On iOS only the caller may restart ICE

**Evidence:** Source.

**Where**
- **iOS:** the answerer never sends a restart offer: [CallService.swift:1008-1019](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1008-L1019).
- **Android:** both sides restart, and the callee rolls back when both restart at once: [CallService.kt:1004-1023](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1004-L1023), [CallService.kt:2420-2472](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2420-L2472).

**On a weak network.** When an iOS answerer walks from Wi-Fi to LTE, its network monitor fires, but it only waits. The caller notices only after its own ICE goes `disconnected` and the 3 s grace passes. The restart offer then travels over signaling that is itself reconnecting. That is several seconds of silence per network switch at best. If the caller's offer is lost, the call dies (the answerer ends after 30 s, LD-03). iOS↔Android calls follow different rules on each side.

**Fix.** Let either side start a restart, on both platforms. When both restart at once, reuse the rule already used for simultaneous calls: the lower user id wins, the other side rolls back and answers ([CallService.swift:1437-1457](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1437-L1457), [CallService.kt:932-948](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L932-L948)). Write the rule down once so both platforms implement the same behavior.

---

<a id="ld-09"></a>
### LD-09 · P1 · Network detection triggers unnecessary restarts

**Evidence:** Source.

**Where**
- **iOS:** rebuilds the socket on every path change and counts "back online" as a network switch, which triggers an ICE restart ([CallService.swift:525-543](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L525-L543), [CallNetworkMonitor.swift:37-41](../../apps/ios/Voiid/Voiid/Networking/CallNetworkMonitor.swift#L37-L41)).
- **Android:** registers `registerNetworkCallback(INTERNET)` and treats any other available network as a switch ([CallNetworkMonitor.kt:40-79](../../apps/android/app/src/main/java/com/voiid/app/net/CallNetworkMonitor.kt#L40-L79)). That triggers a restart ([CallService.kt:2305-2310](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2305-L2310)).

**On a weak network.** A weak cell link makes the OS report the path flapping (unavailable ↔ available). On every flap, iOS tears down a working signaling socket and starts an ICE restart; on 2G a new TLS handshake alone takes seconds. Android is told about *every* network with internet, including mobile data kept up in the background while on Wi-Fi. A modem reconnecting in the background can restart a healthy Wi-Fi call, and LD-02's blocking fetch makes it worse. Each unnecessary restart briefly disrupts media.

**Fix**
- Debounce path changes by ~2 s and act only on the settled state.
- iOS: rebuild the socket only if it isn't live (`isLive == false`) or the interface type changed.
- Android: switch to `registerDefaultNetworkCallback`, which reports only the network the system actually routes through.
- Before restarting, check `iceConnectionState`. With `gatherContinually` the connection often recovers from new candidates by itself; restart only if it is still disconnected after the debounce.

---

<a id="ld-10"></a>
### LD-10 · P1 · The send queue can drop the SDP but keep its candidates

**Evidence:** Source.

**Where**
- **iOS:** queue of 128 frames, oldest dropped first: [WebSocketClient.swift:41](../../apps/ios/Voiid/Voiid/Networking/WebSocketClient.swift#L41), [WebSocketClient.swift:576-579](../../apps/ios/Voiid/Voiid/Networking/WebSocketClient.swift#L576-L579).
- **Android:** 256 frames, same policy: [WebSocketClient.kt:38](../../apps/android/app/src/main/java/com/voiid/app/net/WebSocketClient.kt#L38), [WebSocketClient.kt:193](../../apps/android/app/src/main/java/com/voiid/app/net/WebSocketClient.kt#L193).
- Neither the relay nor the clients acknowledge call frames.

**On a weak network.** During a signaling outage, continuous gathering and restarts keep producing ICE candidates. When the queue fills, the oldest frames are dropped first. Those can be the `call_offer` or `call_answer` the candidates belong to, and the peer then gets candidates for an offer or answer it never received. Separately, a frame written into a half-dead TCP connection is lost with no retry.

**Fix**
- Never drop `call_offer`, `call_answer`, `call_hangup`, `call_decline` or `call_busy`. Drop ICE candidates first (oldest first, per call), and drop candidates from a superseded restart.
- Acknowledge SDP and end-of-call frames. The client adds a `msg_id`; the relay replies `call_ack` after publishing; the sender retries at 2/4/8 s with the same `msg_id`; receivers ignore duplicates per call.

---

<a id="ld-11"></a>
### LD-11 · P1 · Callee keeps ringing after the caller hangs up

**Evidence:** Source.

**Where**
- On hangup, decline or busy, the relay deletes the waiting offer and ICE candidates but stores nothing for the callee: [index.ts:926-943](../../backend/websocket/src/index.ts#L926-L943).
- When a socket connects, the relay delivers waiting offers, ICE candidates and "answered on another device" notices, but not hangups: [index.ts:265-340](../../backend/websocket/src/index.ts#L265-L340).
- Clients end a push-rung call only when no offer arrives within 30 s: [CallService.swift:248](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L248), [CallService.kt:217](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L217).

**On a weak network.** The push reaches the callee, but the socket connects slowly. The caller gives up in the meantime. The callee's socket then connects, finds no offer, and the phone keeps ringing for the rest of the 30 s. If they answer, they see "Connecting…" and then a failure. On 2G and 3G this is what users normally see.

**Fix.** Store the hangup for the callee, the same way "answered on another device" notices are stored: `HSET call:ended:<to_user_id> <call_id> <frame>` with the offer's 60 s TTL. Deliver it on connect, before offers. Both clients already end a ringing call when `call_hangup` arrives. This also cleans up late VoIP pushes (LD-12).

---

<a id="ld-12"></a>
### LD-12 · P1 · VoIP push expires before the ring does

**Evidence:** Source.

**Where**
- `VOIP_TTL_SECONDS = 30`: [pushPayload.ts:26](../../backend/api/src/pushPayload.ts#L26), used as `apns-expiration` in [pushPayload.ts:210-226](../../backend/api/src/pushPayload.ts#L210-L226).
- Ring limits: callee 45 s, caller 60 s ([CallService.swift:259-263](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L259-L263), [CallService.kt:219-221](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L219-L221)).
- The FCM ring TTL is already 60 s: [pushPayload.ts:36](../../backend/api/src/pushPayload.ts#L36).

**On a weak network.** An iPhone out of coverage when the ring is sent, and back 30–45 s later, never rings, although the caller is still waiting.

**Fix.** Set the VoIP expiry to about 45 s, matching the callee's ring limit. A push that lands after the call ended is already handled: iOS reports it and ends it at once ([CallService.swift:1192-1202](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1192-L1202)). With LD-11, the stored hangup ends it as soon as the socket connects.

---

<a id="ld-13"></a>
### LD-13 · P1 · TURN is fetched on every call, in the slow part of setup

**Evidence:** Source.

**Where**
- **iOS answer path:** TURN is fetched after the user taps Answer ([CallService.swift:1888-1890](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1888-L1890) → [CallService.swift:2379-2384](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2379-L2384)). The 35 s connect deadline starts at the tap ([CallService.swift:1869](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L1869)).
- **Android:** caches TURN for only 4 minutes ([CallService.kt:223](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L223)). Its caller path runs ring, key exchange and TURN one after another ([CallService.kt:416-477](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L416-L477)).
- **iOS caller path:** already runs the TURN fetch alongside the rest of setup ([CallService.swift:769-772](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L769-L772)).

**On a weak network.** With 2G or satellite-like round-trip times, each HTTPS request costs 1–3 s, more if the connection was idle. That time lands on the most visible moment, right after Answer.

**Fix**
- Fetch TURN at app start, on foreground and on socket connect. Cache it until 5 minutes before expiry (see LD-01).
- On the Android caller path, run ring, key exchange and TURN in parallel, as iOS does.
- While ringing, create the peer connection early with `iceCandidatePoolSize = 1–2` (exposed in both builds) so candidate gathering is done when the user answers. Nothing is sent to the caller before Answer. The cost is one TURN allocation per ring, including declined calls.

---

<a id="ld-14"></a>
### LD-14 · P1 · TURN, SFU and API placement

**Evidence:** Verify (outside the repo); Source for what the repo contains.

**Where**
- The coturn config names a single host, `turn.voiid.app`: [turnserver.conf:18-19](../../deploy/turn/turnserver.conf#L18-L19).
- Multi-region TURN is still an open item in [docs/CALL_RELIABILITY.md](../../docs/CALL_RELIABILITY.md), §3 "TURN coverage and placement".
- One box serves both dev and production for API and WebSocket: [deploy-main.yml:8-10](../../.github/workflows/deploy-main.yml#L8-L10).
- LiveKit is one "bare `livekit/livekit-server` Docker container" whose config is not in the repo: [deploy-main.yml:20-22](../../.github/workflows/deploy-main.yml#L20-L22).
- The API already supports Cloudflare TURN: [turn.ts:63-92](../../backend/api/src/turn.ts#L63-L92).

**On a weak network.** Relayed media always passes through the TURN server. If it sits in one region, users on other continents get a long detour on every packet. Group calls add the SFU detour for everyone. If LiveKit's TURN or TCP fallback is off, group calls fail outright on networks that block UDP (hotels, offices, some carriers).

**Verify on the servers** (not checked in this audit)
1. Which TURN provider production uses (`VOIID_TURN_CLOUDFLARE_*` or `VOIID_TURN_URLS`), and that `GET /calls/turn` returns UDP, TCP and TLS-on-443 entries.
2. LiveKit `config.yaml`: `rtc.tcp_port` set, UDP port range open, `rtc.use_external_ip`, `turn.enabled` with a TLS certificate on 443, and `rtc.congestion_control` enabled with `allow_pause`.
3. That a relayed 1:1 call lasting longer than `VOIID_TURN_TTL_SECONDS` (default 3600 s) keeps its relay.

**Fix**
- Use Cloudflare TURN (anycast, already supported in code) or coturn in at least three regions.
- Use LiveKit Cloud, or regional LiveKit servers with TURN over TLS on 443.
- Commit the LiveKit config, without secrets, under `deploy/`.

---

<a id="ld-15"></a>
### LD-15 · P1 · Group calls publish with SDK defaults

**Evidence:** Source + SDK.

**Where**
- **iOS** group and conference rooms set only `adaptiveStream`, `dynacast` and encryption: [GroupCallService.swift:222-227](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L222-L227), [GroupCallService.swift:302-307](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L302-L307).
- **Android** does the same: [GroupCallService.kt:220-227](../../apps/android/app/src/main/java/com/voiid/app/net/GroupCallService.kt#L220-L227), [CallConferenceService.kt:765-776](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L765-L776).
- **Defaults in the linked LiveKit Swift SDK 2.15.2:**
  - camera capture: 720p at 30 fps (`CameraCaptureOptions.swift:48-49`)
  - simulcast: on (`VideoPublishOptions.swift:47`)
  - audio: `encoding: nil`, with RED and DTX on (`AudioPublishOptions.swift:34-37`)
- Android LiveKit 2.27.0 publish defaults were not checked in detail.

**On a weak network.** Every participant captures and uploads 720p simulcast, and audio carries redundancy, whatever the link. There is no "audio only" or "use less data" option. The UI doesn't show the per-participant connection quality the SDK provides.

**Fix**
- **Explicit publish defaults:**
  - camera: 540p at 24 fps
  - simulcast layers: 180p and 360p, top layer ≤ 600 kbps
  - audio: speech preset (24 kbps), DTX on, RED only when loss is high
- **Low-data profile:** stop publishing video, and receive others' video at low quality or not at all (`setVideoQuality` / `setSubscribed`).
- **UI:** show `ConnectionQuality` on each tile.

---

<a id="ld-16"></a>
### LD-16 · P1 · Group join and key deadlines are too tight

**Evidence:** Source.

**Where**
- **Join deadline, 35 s:** iOS [GroupCallService.swift:124-135](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L124-L135); Android [GroupCallService.kt:155](../../apps/android/app/src/main/java/com/voiid/app/net/GroupCallService.kt#L155) and conference [CallConferenceService.kt:685](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L685).
- **iOS key failure:** tears down the whole call if any one track reports a missing or failed key for 8 s ([GroupCallService.swift:118](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L118), [GroupCallService.swift:742-759](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L742-L759)).
- **Android conference key wait:** gives up after 8 s ([CallConferenceService.kt:716-727](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L716-L727)).

**On a weak network.** The 35 s covers the token request, key work, SFU connection, ICE and publishing. On high-RTT links it can run out while progress is still being made. The 8 s key timer is worse: on a slow link, a membership change takes several requests to reach every device. One participant's late key removes you from a call that is otherwise working.

**Fix**
- Give joins 60 s, with visible steps ("Getting keys…", "Connecting…").
- Allow 30 s for key recovery, per remote participant: show that person's tile as "Waiting for encryption keys". Never end your call because of one participant's key.
- Keep the rule that media is never sent unencrypted.

---

<a id="ld-17"></a>
### LD-17 · P2 · iOS socket reconnects slowly during a call

**Evidence:** Source.

**Where**
- **iOS:** backoff 1 → 30 s with no call-time cap ([WebSocketClient.swift:328-340](../../apps/ios/Voiid/Voiid/Networking/WebSocketClient.swift#L328-L340)). One-way heartbeat every 30 s, no ping/pong ([WebSocketClient.swift:591-596](../../apps/ios/Voiid/Voiid/Networking/WebSocketClient.swift#L591-L596)).
- **Android** already caps backoff at 5 s during calls and uses OkHttp pings: [WebSocketClient.kt:39-45](../../apps/android/app/src/main/java/com/voiid/app/net/WebSocketClient.kt#L39-L45), [WebSocketClient.kt:235-248](../../apps/android/app/src/main/java/com/voiid/app/net/WebSocketClient.kt#L235-L248).

**On a weak network.** When the network type doesn't change, an iOS socket that failed a few times waits up to 30 s before retrying. Restart offers and hangups wait with it. A half-open connection goes unnoticed until a send fails.

**Fix.** Copy Android's call-time cap (≤ 5 s). During a call, use `URLSessionWebSocketTask.sendPing` every 10 s, and reconnect if no pong arrives within 5 s.

---

<a id="ld-18"></a>
### LD-18 · P2 · Only Google STUN

**Evidence:** Source.

**Where.** Server default `stun:stun.l.google.com:19302` ([turn.ts:24-27](../../backend/api/src/turn.ts#L24-L27)). The client fallbacks use the same server ([CallService.swift:2470-2473](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2470-L2473), [CallService.kt:2852-2855](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2852-L2855)).

**On a weak network.** Where Google services are blocked (for example mainland China), STUN fails, so each phone can't learn its public address. Every call then depends on TURN; if TURN also failed (LD-01), it doesn't connect.

**Fix.** Use two STUN providers, one of them yours. The coturn host already answers STUN on 3478; add `stun:stun.cloudflare.com:3478` as the second. Set `VOIID_STUN_URLS`, and use the same list in the client fallbacks.

---

<a id="ld-19"></a>
### LD-19 · P2 · HTTPS polling during group and conference calls

**Evidence:** Source.

**Where**
- **Conference roster:** `GET /calls/:id/participants` every 3 s, on iOS ([CallConference.swift:766-775](../../apps/ios/Voiid/Voiid/Networking/CallConference.swift#L766-L775)) and Android ([CallConferenceService.kt:654-663](../../apps/android/app/src/main/java/com/voiid/app/net/CallConferenceService.kt#L654-L663)).
- **Group presence:** `POST /calls/group/heartbeat` every 20 s ([GroupCallService.swift:441-460](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L441-L460), [GroupCallService.kt:576-599](../../apps/android/app/src/main/java/com/voiid/app/net/GroupCallService.kt#L576-L599)).

**On a weak network.** Constant HTTPS traffic competes with media on a thin uplink and keeps the cellular radio in high-power mode. With high RTT, the 3 s poll is nearly continuous.

**Fix**
- Push roster changes over the WebSocket relay; it already carries `call_invite_accept` and `call_invite_decline`. Poll every 15–30 s only as a fallback.
- Derive group presence from LiveKit webhooks (`participant_joined` / `participant_left`) or the socket heartbeat, and drop the HTTP heartbeat.

---

<a id="ld-20"></a>
### LD-20 · P2 · Group ring waits until the starter has connected

**Evidence:** Source.

**Where.** The ring is sent only after `room.connect` and publishing succeed: [GroupCallService.swift:232-260](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L232-L260), [GroupCallService.kt:241-254](../../apps/android/app/src/main/java/com/voiid/app/net/GroupCallService.kt#L241-L254).

**On a weak network.** On a slow uplink, other members' phones start ringing only after the starter has fully connected, which can take many seconds.

**Fix.** Send `/calls/group/ring` as soon as the token is issued, in parallel with connecting. If the join then fails, send a cancel, or let the presence banner expire as it does today.

---

<a id="ld-21"></a>
### LD-21 · P2 · Low Data Mode and Data Saver are ignored for calls

**Evidence:** Source.

**Where**
- **iOS:** `CallNetworkPath` records `isExpensive` and `isConstrained` ([CallNetworkMonitor.swift:31-32](../../apps/ios/Voiid/Voiid/Networking/CallNetworkMonitor.swift#L31-L32), [CallNetworkMonitor.swift:70-75](../../apps/ios/Voiid/Voiid/Networking/CallNetworkMonitor.swift#L70-L75)), and no call code reads them. Clips already do ([ClipQuality.swift:56-89](../../apps/ios/Voiid/Voiid/Networking/ClipQuality.swift#L56-L89)).
- **Android:** no call code reads the metered or Data Saver state.

**Fix.** Add a "Use less data for calls" setting: Off / On mobile data / Always. Turn it on automatically when iOS Low Data Mode (`isConstrained`) or Android Data Saver (`ConnectivityManager.getRestrictBackgroundStatus()`, `isActiveNetworkMetered`) is on. It starts calls in the *Low* profile (§3.2) and caps group video.

---

<a id="ld-22"></a>
### LD-22 · P2 · Oversized signaling and connection setup

**Evidence:** Source + SDK (both builds expose `tcpCandidatePolicy`; TURN port pruning is `shouldPruneTurnPorts` on iOS and `turnPortPrunePolicy` on Android).

**Where**
- Every codec the default factories support ends up in the SDP ([CallService.swift:176-181](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L176-L181), [CallService.kt:273-278](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L273-L278)).
- Each ICE candidate is its own frame ([CallService.swift:2523-2530](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2523-L2530), [CallService.kt:1835-1846](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1835-L1846)).
- The relay server has no `perMessageDeflate` ([index.ts:394](../../backend/websocket/src/index.ts#L394)).
- Connection configs set no `tcpCandidatePolicy` and no TURN port pruning ([CallService.swift:2385-2390](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L2385-L2390), [CallService.kt:1748-1754](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L1748-L1754)).

**On a weak network.** Each setup sends several KB of SDP and a stream of small frames, and gathers TCP host candidates that rarely help on mobile. With several TURN URLs, the phone opens relay connections, including TLS handshakes, to all of them at once, at the moment the link is busiest.

**Fix**
- Call `setCodecPreferences` on each transceiver to keep only the codecs used (Opus, plus one or two video codecs with RTX). Every renegotiation shrinks too.
- Set `tcpCandidatePolicy = disabled`. TURN over TCP/TLS still covers networks that block UDP.
- Turn on TURN port pruning.
- Send ICE candidates in ~100 ms batches as one frame (the relay and clients need a `candidates` array).
- Turn on WebSocket compression if both client stacks support it; check OkHttp and `URLSessionWebSocketTask`. If they don't, trimming the SDP gets most of the gain.

---

<a id="ld-23"></a>
### LD-23 · P2 · Platforms disagree on "poor", and neither can tell whose link is bad

**Evidence:** Source.

**Where**
- **iOS "poor":** loss ≥ 8% or RTT ≥ 500 ms ([CallStatsCollector.swift:335-336](../../apps/ios/Voiid/Voiid/Networking/CallStatsCollector.swift#L335-L336)).
- **Android "poor":** loss ≥ 5% or RTT ≥ 400 ms ([CallStats.kt:225-226](../../apps/android/app/src/main/java/com/voiid/app/net/CallStats.kt#L225-L226)).
- **Loss source:** only incoming media, `inbound-rtp` ([CallStatsCollector.swift:211-221](../../apps/ios/Voiid/Voiid/Networking/CallStatsCollector.swift#L211-L221), [CallStats.kt:146-154](../../apps/android/app/src/main/java/com/voiid/app/net/CallStats.kt#L146-L154)). Neither reads `candidate-pair.availableOutgoingBitrate` or `remote-inbound-rtp.fractionLost`.

**Fix**
- Use one threshold table on both platforms.
- Judge "my connection" from available outgoing bitrate and the peer's loss report on my stream.
- Judge "their connection" from my incoming loss, jitter and audio concealment.
- Feed both into the LD-06 controller.

---

<a id="ld-24"></a>
### LD-24 · P3 · Metrics can't answer low-data questions

**Evidence:** Source.

**Where.** [CallStatsCollector.swift:61-75](../../apps/ios/Voiid/Voiid/Networking/CallStatsCollector.swift#L61-L75); Android request body at [CallStats.kt:250-271](../../apps/android/app/src/main/java/com/voiid/app/net/CallStats.kt#L250-L271).

**Fix.** Add numeric fields, keeping the privacy rules written in those files (no network type, no identifiers):
- seconds spent reconnecting
- seconds in each media profile
- seconds with video paused for the network
- audio concealment %
- total video freeze time
- median available outgoing bitrate, in buckets

---

<a id="ld-25"></a>
### LD-25 · P3 · Verification tag sent three times regardless

**Evidence:** Source.

**Where.** [CallKeyExchange.swift:443-461](../../apps/ios/Voiid/Voiid/Networking/CallKeyExchange.swift#L443-L461) and [CallService.kt:2036-2046](../../apps/android/app/src/main/java/com/voiid/app/net/CallService.kt#L2036-L2046) send the tag three times, even after the peer's tag has arrived.

**Fix.** Stop once the peer's tag has arrived; both sides already record it.

---

<a id="ld-26"></a>
### LD-26 · P3 · WebRTC version doc is out of date for iOS 1:1

**Evidence:** Source.

**Where.** [docs/WEBRTC_VERSIONS.md](../../docs/WEBRTC_VERSIONS.md) ("Current pins") says iOS 1:1 calls use the vendored stasel `WebRTC.xcframework` (M150). But `CallService.swift` imports `LiveKitWebRTC` and uses `LKRTC*` types ([CallService.swift:27](../../apps/ios/Voiid/Voiid/Networking/CallService.swift#L27)), and Package.resolved pins `webrtc-xcframework` 144.7559.11. The header comment in [GroupCallService.swift:16-25](../../apps/ios/Voiid/Voiid/Networking/GroupCallService.swift#L16-L25) repeats the old claim.

**Fix.** Update the doc so security-patch tracking follows the build that actually ships.

---

## 3. Optimization plan

### 3.1 Network profiles and targets

| Network | Rough conditions | Target |
|---|---|---|
| Good Wi-Fi / 4G/5G | ≥ 1.5 Mbps, RTT < 150 ms, loss < 1% | HD video, connect < 2 s |
| Weak 4G / 3G | 0.3–1.5 Mbps, RTT 150–300 ms, loss 1–3% | 360–540p video, clear audio, connect < 4 s |
| EDGE / congested / far from relay | 60–300 kbps, RTT 300–800 ms, loss 3–10% | Clear audio; video paused or 180–240p; connect < 8 s |
| Survival | 30–60 kbps or loss 10–20% | Understandable audio, video off, call stays up |
| Outage | 0 kbps for a while | "Reconnecting…", recover within 90 s |

### 3.2 One adaptation controller, same on both platforms

**Inputs, sampled every 2 s**
- `candidate-pair.availableOutgoingBitrate`
- `remote-inbound-rtp` `fractionLost` and `roundTripTime` (the peer's view of my stream)
- `inbound-rtp` loss, jitter and `concealedSamples` (my view of theirs)
- OS flags: iOS `isConstrained` / `isExpensive`, Android metered / Data Saver
- the LD-21 user setting

**1:1 profiles.** Starting points; tune with the §6 tests.

| Profile | Enter when (4 s) | Audio | Video send | Capture |
|---|---|---|---|---|
| HD | available out ≥ 1.8 Mbps, loss < 2%, RTT < 200 ms | ≤ 32 kbps, 20 ms | ≤ 1.5 Mbps, full resolution, 30 fps | 1280×720 @30 |
| Standard (default start) | 0.6–1.8 Mbps | ≤ 32 kbps, 20 ms | ≤ 600 kbps, ~960×540, 24–30 fps | ~960×540 @30 |
| Low | 0.2–0.6 Mbps, or low-data setting | ≤ 24 kbps, adaptive packet time | ≤ 250 kbps, ~640×360, 15 fps | ~640×360 @15 |
| Very low | 80–200 kbps, or loss 8–15% | ≤ 16 kbps, 40–60 ms packets | paused (`active = false`) | stopped |
| Survival | < 80 kbps, or loss > 15% | ≤ 12 kbps, 60 ms packets, FEC on | off | stopped |

**Rules**
- Step down after 4 s below the current band. Step up only after 10 s comfortably above the next band's threshold; the unequal timing prevents flapping.
- Video goes first; audio never goes below *Survival*.
- Apply changes with `RtpSender.setParameters`, never with renegotiation.
- On an ICE restart or network change, drop one profile at once and measure again.
- Voice-first video calls: include both tracks in the offer, but keep video off until the first 2–3 s of stats show at least *Low*.

**UI**
- "Weak connection" (mine).
- "Their connection is weak" (from the peer's hint, or my incoming stats).
- "Video paused to keep audio clear", with a "Try video" button that forces one step up for 10 s.

### 3.3 Connecting fast on slow links

- Cached TURN config, refreshed in the background (LD-01, LD-13).
- Android caller setup runs in parallel like iOS (LD-13).
- Candidates gathered early while ringing (`iceCandidatePoolSize`).
- Warm connections: when a call screen opens, make sure the socket is live and refresh TURN if the cache is stale. Reuse HTTP/2 connections.
- Smaller SDP, batched candidates, no TCP host candidates, pruned TURN connections (LD-22).

### 3.4 Staying connected

- 90 s reconnect time limit; no attempts while offline; either side can restart; debounced network events; TURN kept through restarts (LD-01, LD-03, LD-08, LD-09).
- Signaling: prioritized queue with acks (LD-10), fast iOS reconnect with ping (LD-17), stored hangups (LD-11).
- One shared constants table for both platforms: ring limits already match; add restart, debounce and quality thresholds.

### 3.5 Ringing and notifications

- Fix the group VoIP type (LD-04), raise the VoIP TTL to ~45 s (LD-12), store the caller's hangup for the callee (LD-11).
- Keep what already works: content-free pushes, PushKit for iOS rings, high-priority FCM with a 60 s TTL, retried `/calls/ring`, and Android checks for full-screen-intent and battery-optimization permission ([CallRingCapability.kt:62-65](../../apps/android/app/src/main/java/com/voiid/app/net/CallRingCapability.kt#L62-L65)).

### 3.6 Group calls

- Explicit publish defaults and a low-data profile (LD-15).
- Longer, per-participant timers (LD-16); push instead of polling (LD-19); ring in parallel with joining (LD-20).
- In low data, receive video only from the active speaker, at the lowest layer.
- Server: congestion control with pausing, TURN over TLS on 443, regional placement (LD-14).

### 3.7 Infrastructure

- **TURN:** Cloudflare or three or more coturn regions. Return UDP 3478, TCP 3478 and TLS 443, UDP first.
- **STUN:** two providers (LD-18).
- **SFU:** LiveKit Cloud or regional servers, with TURN over TLS on 443.
- **API and WebSocket:** ring, TURN and token requests all go to one server. Terminate TLS closer to users (edge proxy or regional ingress) to cut handshake time. Confirm HTTP/2 and HTTP/3 are on in Caddy.

---

## 4. Implementation order

| Phase | Goal | Findings |
|---|---|---|
| 1 | Stop self-inflicted drops (small changes, big wins) | LD-01, LD-02, LD-04, LD-11, LD-12, LD-09, LD-03 |
| 2 | Media that adapts to the network | LD-05, LD-06, LD-07, LD-23, LD-21 |
| 3 | Signaling and faster setup | LD-08, LD-10, LD-13, LD-17, LD-22, LD-18 |
| 4 | Group calls | LD-15, LD-16, LD-19, LD-20 |
| 5 | Infrastructure and measurement | LD-14, LD-24 |
| — | Cleanup | LD-25, LD-26 |

---

## 5. What already works

- Opus in-band FEC and DTX on both platforms.
- Ring before offer, with 3 quick retries on transport failures, on both platforms.
- iOS caller runs the TURN fetch and key exchange in parallel with the ring.
- The relay stores the offer and ICE candidates for 60 s, so a push-woken callee can still connect.
- ICE restart on network change exists on both platforms; the gaps above are about its limits and triggers, not its absence.
- Android caps socket backoff at 5 s during calls and uses protocol pings.
- The coturn config listens for TLS on 443, and the API supports Cloudflare TURN.
- Group rooms turn on `adaptiveStream` and `dynacast`.
- Pushes carry no content and have short, per-type TTLs.
- Android checks full-screen-intent and battery-optimization permission for ringing.
- Media is never sent unencrypted when keys are missing. Keep this in every change above.

---

## 6. How to verify on devices

**Tools**
- **iOS:** Network Link Conditioner (Settings → Developer). Use the built-in "Edge", "3G" and "Very Bad Network" presets, plus a custom 50 kbps / 800 ms / 10% loss profile.
- **Android:** emulator `-netspeed` and `-netdelay`. For real phones, a laptop hotspot shaped with `tc qdisc netem` / `tbf`, or an OpenWrt router.
- **Signaling drops:** Toxiproxy in front of the dev WebSocket.
- **Every run:** record getStats (bytes, packets, header bytes, available outgoing bitrate, concealment, freezes) on both phones.

**Matrix.** Run each case iOS↔iOS, Android↔Android and iOS↔Android.

| # | Case | Impairment | Pass |
|---|---|---|---|
| 1 | Voice on EDGE-like link | 60 kbps each way, 300 ms, 3% loss | Connects < 8 s; clear audio for 10 min |
| 2 | Voice, survival | 32 kbps, 600 ms, 10% loss | Call stays up; audio understandable |
| 3 | Video on 3G-like link | 400 kbps | Settles at *Low*; no freeze > 2 s |
| 4 | Video collapse and recovery | 1 Mbps → 100 kbps → 1 Mbps | Video pauses < 5 s, audio uninterrupted; video returns < 15 s after recovery |
| 5 | Full outage | 100% loss for 20 s / 45 s / 80 s | Recovers each time; both sides show "Reconnecting…" |
| 6 | Network switch | Wi-Fi → LTE, caller, then callee | Audio gap < 3 s either way |
| 7 | Cancel while callee is slow | Callee on EDGE, caller hangs up at 5 s | Callee stops ringing ≤ 2 s after its socket connects |
| 8 | Late signal | Callee offline for the first 35 s | Callee still rings |
| 9 | UDP blocked | Only TCP 443 open | 1:1 connects via TURN/TLS; group call connects via LiveKit TURN |
| 10 | Google blocked | Block `stun.l.google.com` | Calls still find a public address via the second STUN provider |
| 11 | Group of 4 on weak links | 300 kbps each | Everyone hears everyone; low video layer; nobody removed by the key timer |
| 12 | Long relayed call | Force relay, 65+ min | Call stays up past the TURN TTL |
| 13 | Group ring on iOS | Start a group call; iOS member locked | CallKit ring, Answer joins the room (LD-04) |

---

## 7. What this audit checked

**Read line by line:**
- **iOS:** `CallService.swift`, `CallStatsCollector.swift`, `CallNetworkMonitor.swift`, `CallSDPTuning.swift`, `WebSocketClient.swift`, `VoIPPushManager.swift`, `GroupCallService.swift`
- **Android:** `CallService.kt`, `WebSocketClient.kt`, `CallStats.kt`, `CallNetworkMonitor.kt`, `GroupCallService.kt`
- **Backend:** `turn.ts`, `callSignaling.ts`, `callConference.ts`, `common-utils/callGrant.ts`, `pushPayload.ts`, `missedCallNotifications.ts`
- **Deploy and docs:** `deploy/turn/*`, `docs/CALL_RELIABILITY.md`, `TURN_SETUP.md`, `LIVEKIT_SETUP.md`, `WEBRTC_VERSIONS.md`, `CALL_AUDIT_2026-09-09.md`

**Read the relevant sections:** `routes/calls.ts` (TURN, ring, group token, presence, group ring), `push.ts` (VoIP sending), `websocket/src/index.ts` (call relay and connect-time delivery), `CallConference.swift`, `CallConferenceService.kt`, `CallConference.kt`, `CallKeyExchange.swift`, `APIClient.swift`, `ApiClient.kt`.

**Searched only (no bandwidth impact found):** call screens, CallKit and Telecom integration, tones, audio routing, foreground service, `VoiidMessagingService.kt`.

**SDK checks on this machine:** `LiveKitWebRTC.framework` headers from the iOS build; `stream-webrtc-android` 1.3.8 classes via `javap`; LiveKit Swift SDK 2.15.2 and Android 2.27.0 sources in the local build caches.

**Not done:** device calls, network-impairment runs, reading the production `.env`, the LiveKit server config, or TURN server state. Bitrate figures are estimates until §6 is run.

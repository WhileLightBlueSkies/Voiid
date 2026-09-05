# 16 — Product acceptance and performance gates

Baseline: `a2e24e5` · Status: TODO. These are proposed project targets and verification work, not observed results or universal industry guarantees.

## Measurable performance contract

Record app/server SHA, release build, OS/device/refresh rate, thermal state, network RTT/loss, dataset size, test duration and percentile sample count. Compare identical before/after scenarios. Debug builds and emulators are not evidence of production frame performance.

| Surface | Initial target | Measurement |
|---|---|---|
| Immediate touch feedback | Next rendered frame; no deliberate network wait | High-speed interaction trace/video |
| 60Hz rendering | Work fits 16.67ms/frame; <1% janky frames during sustained core flows | Android FrameTiming/Perfetto; iOS Instruments |
| 120Hz rendering | Work fits 8.33ms/frame on qualified hardware | Same test at native refresh; report actual pacing |
| Glass overhead | p95 added frame cost ≤2ms on agreed mid-tier; jank increase ≤1 percentage point | Identical enabled/disabled scroll and sheet runs |
| Warm navigation | Visible local content within 100ms p95 | Signposts/trace; distinguish data fetch completion |
| Cold launch | First useful local screen ≤2s p95 on agreed mid-tier | Release Macrobenchmark / XCTest metrics |
| Common API read | ≤150ms p95 / ≤400ms p99 server duration | Route-level histogram; network latency reported separately |
| Send acceptance | ≤250ms p95 / ≤600ms p99 server duration for representative group sizes | Durable commit latency; notifications async |
| Message receipt over healthy connection | ≤500ms p95 end-to-end on controlled same-region network | Client timestamps correlated with accepted/store acknowledgement |
| Basic dependency failure | Bounded response, normally ≤3s for core API dependency failure | Fault injection; job-specific exceptions documented |
| Idle app | No continuous glass/render work when backgrounded | CPU/GPU/battery trace |
| Long session memory | Stabilizes after cache warmup; no sustained growth over 30 minutes | Native memory instruments and server heap/queue metrics |

Targets must be calibrated after baseline collection; retain explicit reasons if adjusted. Define capacity by measured users/connections/messages per second and payload size, not adjectives. Do not tune CPU-heavy game ticks and chat APIs as if they share the same latency workload.

## Load and failure harness

Use disposable synthetic users; no real message plaintext or personal data in traces. Generate 1:1 conversations, 100- and 1,000-member groups with two devices/member, 10k/50k-message local histories, large offline queues and high-churn community feeds. Ramp concurrency gradually and stop at the defined error/latency/resource ceiling. Measure DB pool wait, queries/operation, Redis commands, outbox lag, websocket buffered bytes, event-loop lag, memory and CPU.

Run DB slow/unavailable, Redis restart, delayed/lost HTTP response, websocket disconnect, duplicate event, out-of-order event, process restart and disk-full scenarios. Restore service and prove bounded retry/backlog drain. Never attach a load generator to production by default.

## Native device and accessibility matrix

- Android API 24/25 compatibility, API 30 fallback, API 31/32 blur, API 33+ shader, API 36 target behavior. Physical low/mid-tier and high-refresh devices; at least one non-Google OEM for background/call behavior.
- iOS minimum supported deployment target from the current project settings, plus iOS 26 native glass and current supported OS. Phone sizes, landscape and supported tablet/window layouts.
- Light/dark/system theme, high contrast, reduced transparency, reduced motion, largest accessibility text, Android 200% font scaling, TalkBack/VoiceOver, external keyboard, display cutouts and gesture navigation.
- Normal, low-power and thermally stressed sessions; flaky cellular, Wi-Fi↔cellular, offline launch, locked device, process-killed and notification-launched states.

## End-to-end acceptance by feature

| Feature | Required scenarios | Evidence to retain |
|---|---|---|
| Sign-in/onboarding | OTP expiry/retry, cancellation, reinstall, incomplete profile, update gate, denied permissions | Both platform test recordings and auth assertions |
| Device linking/logout | QR expiry, double approval/poll, lost response, one-device revoke, all-account logout | Device/session state before/after and negative API tests |
| Private 1:1 chat | Text, media, voice, reply, forward, reaction, edit/delete if supported, block/unblock, offline resend | No duplicate bubble; correct recipient entitlement; persistence/ack proof |
| Group chat | Add/remove/leave/admin/owner transfer, simultaneous changes, old/new member keys, 1k-member fanout | Membership/crypto and performance results |
| Note to Self | One device and linked-device cases, empty fanout, media/reactions | Local persistence without false failures |
| Private media | Bounded upload/download, invalid/oversize MIME/length, interrupted transfer, orphan cleanup, corrupt ciphertext | Memory/size budgets and no private-key leakage |
| Calls | 1:1↔conference, outsider/blocked invites, join/leave/cap races, microphone/camera denial, Bluetooth, hold, PiP | Real A/B/C devices; frame/key/push and lifecycle results |
| Killed-state calls | Push before socket, duplicate push, answer on other device, late offer/ICE, timeout/decline/end | No ghost ring or call resurrection; content-free payload |
| Stories | Audience changes, multi-device keys, seen status, expiry offline, retry/deletion backlog | Expiry/authorization and object cleanup evidence |
| Maps/location | Permission denial/revoke, share start/stop/extend/leave, ghost mode, stale/out-of-order fixes | No server plaintext coordinate; no update after revoke/expiry |
| Clips | Camera/gallery, trim/filter/audio/export, portrait/landscape, playback prefetch, scroll away/background, report | CPU/memory/decoder/player disposal, error recovery and accessibility |
| Communities/creators | Discover/join/invite/ban/mute, announcement posting, host thread, follows, public/private distinction | Role matrix; shared membership never grants unrelated messaging |
| Events/tickets/payments | Inventory contention, idempotent checkout, webhook retry/order reversal, refund, ticket scan replay/expiry | Disposable provider fixtures, one settlement/ticket outcome |
| Tournaments/games | Invite acceptance/expiry, join/leave, duplicate commands, deadline, reconnect/forfeit, worker loss | One authoritative outcome, bounded queues, hidden state protected |
| Game visuals | Snake interpolation; Ludo movement; cricket/RPS/TicTacToe/Sea Battle controls, sound/haptics | Per-game cross-platform screenshots and frame traces |
| Recovery/backup | Phrase recovery, wrong credential, corrupt blob, old format, interrupted restore, identity/session consistency | Threat-model approval and data-preservation checks |
| Account deletion | Immediate access stop, active calls/sockets, local wipe, delayed DB/object cleanup, retries | Synthetic account trace; no orphan cleanup intent |
| Admin | Each role, search/filter races, cancel, moderation, export/erasure controls, audit log | Authorization checks and browser interaction tests |
| Web | All routes, responsive menu, keyboard, screen reader, reduced motion/transparency, production build | Accessibility/build results and performance baseline |

For each row record status, platform coverage, test ID, artifact link, owner, and remaining limitations. An empty row is unverified, not a pass.

## Definition of release-ready

All P0 tasks verified; P1 tasks closed or explicitly scoped out of the release; no silent data-loss path; full required device matrix; tested rollback/restore; no unsupported security claims. Glass may be enabled per qualified device tier only after its own visual and performance gates pass. Produce a concise evidence report linked from the issue register.

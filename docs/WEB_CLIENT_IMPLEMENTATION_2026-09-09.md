# Web companion implementation — 2026-09-09

This is a local **1:1 text messaging preview**, not the completed production roadmap. It has
not been deployed to the backend. After the local checks, the signed iOS build was installed and launched on the connected iPhone 15 at the user’s request. The current Android Debug app was also built in isolated output directories, installed in place, launched and confirmed running; its browser-approval UI is still pending. Browser linking itself remains unverified live because the development server does not yet expose `/v1/linking/preview`.

## Linking on iOS

Settings → Linked Devices → Link a Browser opens a dedicated approval screen using the
existing `ScannerController`. The profile QR scanner still accepts profile links only.

1. Browser generates its own Olm identity in a dedicated worker and persists it encrypted.
2. API creates a five-minute request, returning a QR token and a separate random redemption
   secret. Only the QR token appears in the QR. The database stores the secret's SHA-256 hash.
3. iOS accepts only `voiid://link?token=<32 base64url characters>` in this scanner. Duplicate
   parameters, fragments, user information, ports and unrelated URLs are rejected.
4. An active phone can preview the request. The phone and browser show the same 12-hex-digit
   key comparison code. The browser name is client supplied, not an attested identity.
5. Explicit confirmation invokes Face ID or the device passcode through LocalAuthentication.
   The API then validates the active phone under a transaction lock and checks that the
   approved identity key matches the preview. A scan or preview never approves a device.
6. Device insertion, device-bound session creation and approval commit together. Registration
   collisions return a conflict instead of overwriting or resurrecting another device.
7. The browser must present its independent redemption secret to collect its session, once.

An approved request whose collection response is lost requires a fresh link. The unused
companion should be removed from Linked Devices. Old requests without a proof hash fail closed.

## Browser and server implementation

- Separate React app in `apps/web-client`, with the actual iOS light/dark Tide tokens and local
  brand asset. No marketing, analytics, third-party scripts or remote fonts in the messenger.
- WASM compiles the existing native `keys.rs`, `session.rs`, `media.rs`, and `error.rs` modules.
  It exposes no native recovery, PIN or calling functions. WASM is approximately 396 KiB raw.
- AES-GCM encrypted IndexedDB snapshot with a non-extractable WebCrypto wrapping key. Session
  JWT, identity pickle, ratchets, deduplication records, messages and outbox live in that
  snapshot. LocalStorage contains only a non-secret linked marker.
- A Web Lock covers the crypto worker's lifetime. Additional tabs are blocked; they do not
  create another identity, write ratchets or poll a second linking request.
- Incoming ciphertext and advanced ratchets commit before delivery ACK. Storage failure stops
  the worker's mutation queue. Reload resumes from the last durable snapshot.
- Outbox persists stable message IDs and exact ciphertext before sending. Network retry does
  not encrypt again. A failed recipient lookup rolls back preparation in memory, and the draft
  is retained until its encrypted outbox record is durable.
- Existing conversations, 1:1/self text, per-device Olm fan-out, native wire format, key top-ups,
  pending-message sync, local history, read receipts, socket reconnect and browser sign-out.
- Signed `client: web` JWT capability restricts the API to messaging and self-revocation.
  Account management, recovery, device registration, call actions and approving more devices
  are denied. Server checks remain authoritative regardless of the UI or user agent.
- Browser socket URLs contain one-use, 20-second Redis tickets instead of session JWTs. Exact
  configured Origin is required. Existing durable session/revocation checks remain in force.
- Dedicated origin with restrictive CSP, no inline JavaScript, no framing, no-store responses,
  no referrers, same-origin resources and no camera/microphone/geolocation permissions on web.

## Validation completed

- iOS generic-device Debug build, signing disabled: passed. A subsequent signed device build was installed and launched on the connected iPhone 15. Camera/Face ID linking has not been exercised live.
- Swift QR parser: valid input accepted; nine malformed/unrelated payloads rejected.
- API and relay TypeScript checks; web production bundle and TypeScript: passed.
- Real local PostgreSQL linking and relay-session tests: copied QR/wrong proof, key-bound
  approval, collisions, simultaneous approval/redemption, browser restrictions, revocation,
  unavailable database/cache and one-use Origin-bound ticket checks.
- Existing native API device registration/session/revocation regression: 9 tests passed.
- Four actual WASM/native crypto tests: both initiation directions, Unicode, native wire
  encoding, encrypted restore, replay/wrong-key rejection, media interop and tamper rejection.
- Three isolated Chromium tests using real worker/WASM/IndexedDB and a controlled API fixture:
  light/dark/mobile linking UI and tab lock; native-decryptable text and exact retry/reload;
  forced storage failure with no ACK followed by successful reload/decryption.

A dedicated CI job now prepares WASM/native fixtures and runs web type, build, crypto and Chromium checks. The updated GitHub workflow has not been run remotely.

Browser fixture approval is simulated. These checks do not establish that a production API,
real iPhone and live relay have successfully completed a link together.

## Local build and review

```sh
npm install
./packages/e2e-core/build-web.sh
npm run build --workspace @voiid/web-client
npm run start --workspace @voiid/web-client
```

Requires Rust's `wasm32-unknown-unknown` target and `wasm-pack`. The build script chooses the
Rustup toolchain. The web server listens on loopback port 4173 by default, proxies `/api/v1/`
to API port 4000 and `/live` to relay port 4001 `/ws`. Start backend services with an isolated
test database/Redis for local linking. Never replay the tests against production.

```sh
npm run test:crypto:prepare --workspace @voiid/web-client
npm test --workspace @voiid/web-client
npm run test:crypto --workspace @voiid/web-client
npx playwright install chromium
npm run test:browser --workspace @voiid/web-client
```

Browser screenshots are local artifacts in `apps/web-client/test-results/`. The browser tests
simulate API responses without using real accounts. Backend SQL suites require explicitly set
loopback `LINKING_TEST_DATABASE_URL` or `SESSION_TEST_DATABASE_URL` test-database URLs.

## Deployment prerequisites

1. Keep public linking unavailable while upgrading. Apply migration 065 through the normal
   migration runner. Do not leave an older API pod serving unprotected polling routes during
   a mixed-version rollout; disable linking at ingress until all pods have been replaced.
2. Deploy API and relay changes. Set `VOIID_WEB_ORIGIN` on the relay to the exact dedicated
   messenger origin, with no trailing slash. Redis must support `GETDEL` (6.2+).
3. Build and serve the messenger on that separate HTTPS origin. Configure `VOIID_WEB_ORIGIN`
   on the web server. `VOIID_API_UPSTREAM` and `VOIID_WS_UPSTREAM` select internal services;
   these are server configuration, never browser-supplied URLs.
4. Route same-origin API/WS traffic at the trusted ingress for production and preserve the
   verified client address according to the API's `trust proxy` policy. The included local
   proxy does not trust forwarded client-address headers: using it unchanged in production
   aggregates unauthenticated rate limits by proxy address. Validate limits at real ingress.
5. Enable `VOIID_WEB_LINKING_ENABLED=1` on the API only after all services are ready. New linking
   otherwise returns unavailable. Disabling new linking does not terminate existing sessions;
   revoke companions separately when that is intended.
6. Ship the iOS approval screen and verify real camera permission, cancel, wrong QR, expiry,
   Face ID/passcode failure, successful link, live text exchange, reload, network recovery,
   sign-out/revocation and a second tab against that environment.

## Remaining roadmap and security boundaries

Still pending: Android approval UI, group/MLS browser support, attachment upload/download UI,
voice notes, contact discovery/new chats, typing/presence UX, follower-tab intent forwarding,
search over message history, full receipt/history edge cases, persistent storage pressure
matrix, Safari/Firefox coverage, full live relay integration and real-device QA. Browser calls
remain excluded by the original plan. Unsupported groups and attachments direct users to their
phone; old messages have no automatic historical-key transfer.

No implementation can promise “non-hackable.” Non-extractable keys and WASM do not protect
against malicious same-origin JavaScript, a compromised browser/OS, malicious extensions or
an attacker controlling the delivered web bundle. A consenting user can still approve a
phishing QR; a matching code does not attest the website or prove physical proximity. Face ID
is a local phone check, not remotely verified platform attestation. The backend authenticates
the signed phone session; stolen phone credentials remain a threat requiring additional review.

WAHA-style automation is not itself a cryptographic bypass. An authorized session can be
scripted. The implemented boundary limits what that session can do and lets the owner revoke
it. Rate limits, operational monitoring, secure build/deploy controls, security review and
independent penetration testing remain release work, not guarantees inferred from passing
unit tests. This preview uses the native Olm protocol; it does not add a new post-quantum claim.

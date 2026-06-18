# VOIID — API Contract (dev)

> Source of truth for the client networking layers (iOS + Android). Generated
> from `backend/api/src/routes/*`. All routes except `/auth/*` require
> `Authorization: Bearer <our-JWT>`. JSON in, JSON out. Base URL is configurable
> (dev default `http://localhost:4000`).
>
> Last updated: 2026-06-17

## Auth (no bearer token)
- `POST /auth/firebase` — body `{ id_token }` (Firebase ID token from client Phone
  Auth; in dev, `"dev:+91XXXXXXXXXX"` with `AUTH_DEV_BYPASS=1`).
  → `{ token, user_id }`  (token = OUR JWT, store securely)
- `POST /auth/logout` → `{ ok: true }`

## Devices
- `POST /devices/register` — `{ platform, registration_id (int), identity_public_key (b64), device_name?, push_token?, push_provider? }`
  → `{ device_id }`
- `GET /devices/:user_id` → `{ devices: [...] }` (public info)
- `DELETE /devices/:device_id` → `{ revoked: true }`

## Prekeys
- `POST /prekeys/upload` — `{ device_id, signed_prekey: { key_id, public_key (b64), signature (b64) }, one_time_prekeys: [{ key_id, public_key (b64) }] }`
  → `{ uploaded: true }`
- `GET /prekeys/:user_id` → `{ bundles }` (a prekey bundle per device — consumes one one-time prekey)
- `POST /prekeys/refresh` — `{ device_id, one_time_prekeys: [...] }` → `{ refreshed: true }`

## Conversations
- `POST /conversations/create` — direct: `{ type:"direct", member_id }` · group: `{ type:"group", name, member_ids:[...], photo_url? }`
  → direct: `{ conversation_id, existed }` · group: `{ conversation_id }`
- `GET /conversations` → `{ conversations: [{ id, type, name, photo_url, updated_at, last_message_at, last_ciphertext, last_content_type, unread_count }] }`
- `GET /conversations/:id` → conversation detail + members

## Messages
- `POST /messages/send` — `{ conversation_id, ciphertext (b64, OPAQUE), content_type?, media_url?, media_mime? }`
  → `{ message_id, created_at }`  (server relays via Redis→WS; stores ciphertext only)
- `GET /messages/conversation/:id` → `{ messages: [{ id, sender_id, ciphertext, content_type, media_url, media_mime, created_at }] }`
- `GET /messages/pending/:user_id` → `{ messages: [...] }` (offline backlog)

## Receipts
- `POST /receipts/mark` — `{ message_ids: [...], status: "delivered"|"read" }` → `{ marked, status }`
- `GET /receipts/:message_id` → `{ receipts: [...] }`

## Users
- `GET /users/:id` → `{ user }` (id, full_name, photo_url, bio, status_text, username)
- `GET /users/username-available?username=foo` → `{ available: bool, reason? }`
  (format: 3–20 chars, starts with a letter, lowercase letters/digits/underscore)
- `POST /users/profile/update` — `{ full_name?, email?, photo_url?, bio?, status_text?, username? }`
  → `{ user }` · 400 invalid username · **409 username already taken**
- `GET /users/status/:id` → presence/last-seen
- `POST /users/consent` → `{ consent_recorded: true }`
- `DELETE /users/me` → `{ deleted: true }` (DPDP soft-delete)

> **username** is used by the **Clips** feature ONLY. It is NOT a messaging
> identity and NOT used for auth or contact matching. Clips surfaces must never
> expose `phone_number` or `user_id`, and provide no "message this person" path —
> Clips is share-only (see Clips privacy rule in SPEC_NOTES/README).

## WebSocket
- `ws://<host>:4001?token=<our-JWT>` (also accepts `Authorization` header). Unauthenticated sockets are closed (4401).
- Server pushes relayed ciphertext/wake events for the user's channel. Client sends JSON frames (see `backend/websocket/src/index.ts`).

## Error shape
All errors: HTTP 4xx/5xx with `{ error: "<message>" }`. 401 = bad/missing token. 400 = bad request. 429 = rate-limited.

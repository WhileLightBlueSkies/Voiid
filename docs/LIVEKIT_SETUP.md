# LiveKit Setup (group calls)

Backend half of group calling: `POST /calls/group/token` in
`backend/api/src/routes/calls.ts`.

---

## Why an SFU

1:1 calls stay peer-to-peer (see [TURN_SETUP.md](./TURN_SETUP.md)). Group calls
can't: a full mesh makes every participant encode and upload a separate stream to
every other participant, so upload and CPU grow with n². It falls apart past about
four people, and mobile devices are the first to overheat.

LiveKit is an **SFU** (Selective Forwarding Unit): each client uploads **once**,
and the server forwards streams to everyone else.

## This does not weaken end-to-end encryption

The SFU **cannot decrypt media**. LiveKit supports frame-level E2EE: clients
encrypt each media frame before it leaves the device, and the SFU forwards opaque
frames it can only route, never read.

The key comes from our own crypto, not from LiveKit. Clients call
`GroupSession.callKeys(member)` in `e2e-core` to derive a shared call key from the
existing group session, and feed it to LiveKit's E2EE key provider. **That key is
never sent to this API and never reaches the SFU.**

`POST /calls/group/token` is therefore purely an **authorization** endpoint: it
answers "may this user join this room", nothing more. No key material, no media,
and no SDP passes through it.

## Choosing a deployment

**LiveKit Cloud** — managed, global edge, free tier. Fastest path; good default
until scale or data-residency requirements say otherwise. Note that the SFU cannot
read media either way, so using Cloud does not expand who can see call content.

**Self-hosted** — full control over where media transits. Run `livekit-server`
with a Redis instance and a TURN-capable public address; see
<https://docs.livekit.io/home/self-hosting/deployment/>. Realistically this needs
a box with generous bandwidth — an SFU forwards (n-1) streams per participant.

Either way the API only needs a URL, a key, and a secret.

## Environment

```bash
# wss:// URL of the SFU. LiveKit Cloud gives you one per project.
LIVEKIT_URL=wss://voiid-xxxxxxx.livekit.cloud
LIVEKIT_API_KEY=APIxxxxxxxxxxxx
LIVEKIT_API_SECRET=<secret>          # SECRET — signs join tokens
# Optional: join-token lifetime in seconds (default 21600 = 6h).
LIVEKIT_TOKEN_TTL_SECONDS=21600
```

If any of the first three are unset the endpoint returns **503** with
`{ "error": ..., "livekit_configured": false }` rather than 500 — clients should
treat that as "group calling isn't available on this deployment" and hide the
entry point rather than retry.

## The endpoint

```
POST /calls/group/token
Authorization: Bearer <jwt>
{ "conversation_id": "<uuid>" }

200 -> { "url", "token", "room", "identity", "ttl_seconds" }
400 -> conversation_id is not a uuid
403 -> caller is not an active member of that conversation
503 -> LiveKit not configured
```

- **Authorization**: the caller must be an active member (`left_at is null`) of
  the conversation. Without that check any authenticated user could mint a token
  for an arbitrary room id and sit in a call they were never part of.
- **Room name** is derived, not stored: `voiid-<conversation_id>`. The
  conversation *is* the room, so every member resolves the same room with no
  extra state to keep in sync.
- **Identity** is `<user_id>:<device_id>`. It must be unique per device — LiveKit
  evicts an existing participant when a second one joins with the same identity,
  which would kick the user's other device out of the call.

## No new dependency

LiveKit access tokens are ordinary JWTs, so the endpoint signs one with the
`jsonwebtoken` package the API already depends on — `livekit-server-sdk` is not
installed. The claim shape matches LiveKit's documented format:

```json
{
  "iss": "<LIVEKIT_API_KEY>",
  "sub": "<identity>",
  "nbf": 1700000000,
  "exp": 1700021600,
  "video": {
    "room": "voiid-<conversation_id>",
    "roomJoin": true,
    "canPublish": true,
    "canSubscribe": true,
    "canPublishData": true
  }
}
```

Signed **HS256** with `LIVEKIT_API_SECRET`. `canPublishData` enables the in-call
data channel, which clients use for mute state and E2EE key rotation.

If we later need server-side room management (kick, mute, recording, webhooks),
that's the point to add `livekit-server-sdk` — issuing a join token doesn't
justify it.

## Verifying

1. Set the env vars and restart the API.
2. Mint a token:
   ```bash
   curl -s -X POST https://api.voiid.app/calls/group/token \
     -H "Authorization: Bearer <jwt>" -H 'content-type: application/json' \
     -d '{"conversation_id":"<uuid>"}' | jq
   ```
3. Paste the `token` at <https://jwt.io> and confirm the `video` grant and `exp`.
4. Connect with it at <https://meet.livekit.io/?tab=custom> using the returned
   `url` and `token`.

Step 4 confirms the token is valid *without* E2EE; the E2EE path is exercised by
the client once `GroupSession.callKeys()` is wired in.

## Caveat

Nothing here has been run against a real LiveKit server — the endpoint is
typechecked and the claim shape matches LiveKit's documentation, but issuance is
unverified until step 4 above is performed against a live deployment.

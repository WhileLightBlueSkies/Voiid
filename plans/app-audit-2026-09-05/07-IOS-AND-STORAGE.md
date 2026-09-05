# 07 — iOS and shared local storage

Baseline: `a2e24e5` · 2026-09-05 · All tasks TODO; fixes specified, not implemented.

## I01 — Move chat persistence off the main actor and page history

**Priority:** P1 · **Evidence:** Confirmed synchronous work; frame impact unmeasured · **Dependencies:** M02 integration

**Location:** `apps/ios/Voiid/Voiid/Networking/ChatEngine.swift:138`, `:1428`, `:1445`, `:1455`, `:1467`; `Storage/LocalStore.swift:21`, `:172`; Android `net/ChatEngine.kt:1280`, `:1326`.

iOS ChatEngine is main-actor isolated, loads all shards, synchronously reads/decodes shards, and re-encodes a full conversation on persistence. Both platforms retain whole conversation arrays and rewrite shards. Local SQL message APIs also select oldest-first with a limit and are not the established primary chat store.

**Fix:** measure 10k/50k-message histories; introduce a serial storage owner and a bounded paged read model. Prefer the existing transactional local database direction, using a versioned import of shards with counts/checksums and rollback retention. Coordinate app/notification-extension writers. Publish small UI snapshots on the main actor; perform IO/decode/encryption work on a suitable serialized executor. Implement newest-page queries plus older-page cursors before switching UI consumers. Preserve ratchet/session consistency and pending envelopes; do not parallelize mutations of one crypto session.

**Done when:** scrolling, typing, incoming-message bursts, and cold launch stay responsive with large histories; all messages survive migration and app/NSE concurrency; no whole-history encoding occurs per keystroke/message on the rendering thread. Attach Instruments and Android traces rather than claiming speed from the refactor alone.

## I02 — Bound avatar memory and avoid synchronous disk misses in UI

**Priority:** P2 · **Evidence:** Confirmed · **Dependencies:** None

**Location:** `apps/ios/Voiid/Voiid/Networking/AvatarCache.swift:18`, `:20`, `:39`, `:60`, `:68`.

The main-actor cache is an unbounded dictionary; misses synchronously read/decode image data, and writes/jpeg encoding happen in the same actor. Large contact/community lists can grow memory and cause scroll stalls.

**Fix:** use a cost-bounded memory cache, image-size downsampling, coalesced in-flight requests, and an async disk cache with eviction limits. Keep cache ownership safe across accounts and respect memory-pressure notifications. Validate HTTP status/content bounds before decode. Provide a placeholder without synchronous disk IO in a view's body path.

**Done when:** thousands of avatars remain within the documented cache budget; repeated requests coalesce; memory pressure evicts safely; scrolling traces show no disk-read/jpeg-encode work on the main actor; sign-out removes account-private cache data.

## I03 — Retain dirty state when local persistence fails

**Priority:** P0 · **Evidence:** Confirmed failure path · **Dependencies:** M02

**Location:** iOS `Networking/ChatEngine.swift:1461`, `:1462`, `:1467`; Android `net/ChatEngine.kt:1321`, `:1326`, `:1332`; iOS `Storage/VoiidDatabase.swift:296`, `:305`.

Both shard persistence paths clear dirty markers while writes swallow failures. Android falls back from rename to direct overwrite, losing atomic replacement guarantees. Database wrappers often return nil after failed writes. The caller cannot reliably distinguish durable storage from an in-memory update.

**Fix:** return typed persistence outcomes, remove dirty markers only after a successful durable commit, and retain retryable pending state on failure. Use a tested atomic-file mechanism or transactional database; do not truncate the existing file as a rename fallback. Propagate storage failure to acknowledgement logic and a clear recoverable UI state. Quarantine corrupt shards and preserve originals before repair; avoid silently replacing undecodable data.

**Done when:** disk full, permission error, interrupted replacement, corrupted shard, and process death never result in a false durable acknowledgement or silent data replacement. Once storage recovers, pending work commits exactly once and survives restart.

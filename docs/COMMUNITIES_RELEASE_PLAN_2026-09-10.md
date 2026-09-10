# Communities release — 10 September 2026

## Confirmed scope

Enable Communities on iOS and Android. Reset all production communities and their associated data (explicitly authorized by the user), then create exactly **Voiid Jobs**, **Voiid Feedback**, and **Voiid Updates**. Ownership awaits the user's account identifier. Never guess an owner or use fabricated member counts.

## Implementation order

1. Audit current routes, membership/encryption lifecycle, native entry points and admin panel.
2. Keep three existing community roles: owner, admin (moderator), member. Only owners change roles; active admins manage content and membership; members see no privileged queues. Enforce on the server.
3. Mark official communities in the database, independently of their names. Permit full platform-admin management only for marked official communities; keep ordinary community management with their owners. Audit privileged actions.
4. Connect QR scanning to community previews on both platforms. Require explicit Join; a QR grants no role. Honor expiry, revocation, use limits and approval. Preserve profile scanning and keep phone linking separate.
5. Enable native tabs; fix dead invite/share/leave/report actions and admin-role presentation. Preserve public-search opt-in and explain visibility. Jobs/Updates default to manager posting, Feedback to member posting.
6. Validate backend authorization, native builds, admin build, QR parsing and membership edge cases. Inspect channel MLS setup before claiming encrypted Spaces work.
7. Deploy through existing quality gates. Run a reviewed, transactional production reset scoped to community-owned records; delete associated channel/host-thread conversations rather than leaving orphan groups. Purge community media without touching unrelated user media. Seed three real official communities with real memberships and owner.
8. Install device builds where connected and record actual results and unresolved limitations.

## Security boundaries

Public cards, Home posts, rules, links, events and moderation metadata are server-readable under the existing community protocol. Channel chats and private host conversations remain encrypted; the platform admin panel must not claim it can decrypt them. Ordinary community membership does not grant private messaging access to other members. Search visibility does not make channel content public. Official status cannot be set through the ordinary community API.

## Validation checklist

- Public/private search, direct links, malformed QR URLs, expired/revoked/exhausted/wrong-community invites.
- Member cannot change roles/settings; admin cannot appoint admins or remove owner; former admin cannot regain privileges by rejoining.
- Open/approval/invite-only joining, duplicate join, leave/rejoin, pending cancellation, ban/unban.
- Official controls refuse ordinary communities and platform moderators; changes visible on both phones.
- Post policy, roster visibility, settings persistence, share and QR preview, removal and suspension.
- Explicitly separate builds/static tests from real-device, multi-account and production checks.

## Implemented and locally verified

- Communities is enabled in both native tab bars. Profile QR scanners also recognise community links and open a preview; joining remains explicit. Linked-phone scanning stays separate.
- Server-owned official markers are limited to jobs/feedback/updates, with unique keys. Search prioritises them and both apps display the official indicator. Ordinary creation cannot award the marker.
- Official-only platform admin actions are authenticated, role restricted, strictly allowlisted and recorded before execution. Settings, member requests/roles/removal/bans, posts/editing, announcements, rules, links, Spaces/rename/delete and invite creation/revocation are wired. Whole-community deletion requires its exact name and removes backing chats.
- Active owner/admin permissions are consistent across platforms. Removing/leaving clears former admin privileges. Generic conversation membership APIs cannot bypass community approval, bans or roles. Suspension blocks channel sends.
- Android response envelopes for authoring, announcements and channel renaming are corrected. Both platforms have real invitations/QR sharing and rules; Android gains missing link/post/announcement/Space authoring controls. iOS sample rules and inactive duplicate management controls are removed from the visible flow.
- MLS Space setup is now coordinated by one owner device. Membership updates target individual devices, not every device belonging to a user. Each outgoing update is stored with the cryptographic state before sending, and is retried with an idempotency key. A failed Space update does not block another conversation's send.
- Incoming MLS updates have stable server order and explicit acknowledgement after durable state/receipt persistence. Removal/rejoin are reconciled against authenticated MLS member identities. Generic senders are excluded from their own device deliveries.
- A Space without local keys shows an explanation instead of opening a chat that cannot send.
- The existing iOS ChatDetailView modifier chain is split into smaller views to resolve the previous CI compiler time-out without changing chat behavior.

## Validation evidence

- All workspace production builds and workspace tests passed (the initial sandbox run failed because tsx could not open its local IPC socket; the unrestricted rerun passed).
- Real PostgreSQL route integration: **14 tests passed**, including roles, approval/invite limits, ban/rejoin, official scope, post editing, device-targeted MLS retries/acknowledgements and deletion boundaries. Added to CI.
- All **66 migrations** replayed on a new isolated database, and a second replay completed without changes.
- The exact maintenance script was exercised against the isolated database: dry runs changed nothing, seed created exactly three names/six Spaces with the specified owner, repeated seed created no duplicates, reset preserved an unrelated conversation.
- Rust default-feature suite: **106 passed, 4 ignored**, Clippy passed; Apple and all Android ABI libraries rebuilt from this source.
- Android: debug APK and instrumentation APK compiled; **125 JVM tests passed**; lint ratchet passed at the existing **90 errors** (not a lint-clean project).
- iOS signed device build passed; bundle/Firebase resource validation passed. Community QR parser: **17 checks passed**; added to CI. Android counterpart instrumentation checks compile but have not run on a device.

## Limits and remaining release steps

- **Owner account is still awaiting the user's answer.** Never seed the official communities onto an inferred account.
- The production inventory read at the start was seven communities, ten memberships, six Spaces and two posts, with no events/orders. Production reset and deployment must be recorded below when actually performed.
- The iPhone install was attempted but iOS refused to mount its developer image while DLT WORK was locked. Android is disconnected. No cross-device Community lifecycle test has been claimed.
- A new member/device needs the owner's coordinating phone online to receive Space keys. Lost coordinator state is deliberately not replaced with a different group; recovery/handoff requires further work. This release does not establish always-available, owner-independent admission.
- Known R2 objects are queued for deletion through the existing erasure worker. Object keys hidden only inside encrypted payloads cannot be recovered by the server. The reset removes live server data, not copies already downloaded to a user's phone or retained infrastructure backups.
- Home posts/announcements and moderation data are server-readable. Complete admin management does not grant decryption of encrypted Spaces or host DMs, nor does it promise access to their old message plaintext.

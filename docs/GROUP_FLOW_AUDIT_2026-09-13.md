# Group flow audit — in progress

## Confirmed fixes in this pass

- Backend removal policy now recognizes owners, prevents removing the owner, limits admin-on-admin removal to the owner, and requires ownership transfer before the owner leaves a nonempty group.
- Removal now checks that the conversation is a group and evaluates membership under a conversation-row lock, serialized with role changes and transfers.
- Add-member authorization is rechecked under the transaction lock, closing a demotion/removal race.
- Removal/leave emits a group system event after the roster update.
- Both clients fetch current roles and the recipient roster before mutating MLS removal state.
- iOS no longer removes the displayed member optimistically; encryption/roster failures propagate to the screen.
- Android propagates roster-write failures and missing encryption context. Add/remove/role/transfer completion callbacks run only on success. The removal dialog retains errors.

## Blocking findings still requiring implementation

1. iOS GroupInfoView contains empty Add members, Invite via link and Report actions. Exit group currently dismisses the screen without leaving. Mute is local view state.
2. MLS membership commits and server roster writes are separate operations. A failure between them can leave partial state; surfaced errors are not an atomicity/recovery solution. Preflight role checks now reject ordinary unauthorized removals before mutating MLS; concurrent role changes and partial failure still require a coordinated recovery design.
3. Group live-location access after removal needs a complete revocation/rekey audit. Current websocket location relay does not validate the durable share audience; client-held keys and lifecycle controls carry that boundary. The previous Map separation fixes do not resolve this issue.
4. Calls, messaging/media/replies/reactions, notification deep links, offline membership changes and multi-device MLS synchronization still require focused functional tests. Existing code presence is not evidence that each works end to end.

## Validation

The removal policy has executable tests covering every owner/admin/member pair plus owner departure and self-leave. Combined with existing group-role tests, 21 tests pass. Existing role tests include static source assertions; these are not database concurrency tests.

Backend TypeScript and Android builds passed. iOS build verification is tracked in `/tmp/voiid-group-ios.log`.

Changes in this pass are local; no backend deployment or device installation has been performed. This audit is not a completed security review and the group feature is not yet release-ready.

## September 14 — reported group send failure

- Both send paths now synchronize pending MLS events before encrypting a new group message.
- iOS propagates send failures to the chat store and displays its error in the chat screen; group location control also receives a real failure result.
- Android no longer inserts a sent local echo before server acceptance, and propagates missing-session, missing-recipient and HTTP errors.
- Group-info headers were reduced to 88-point avatars and nonfunctional decorative camera/edit/search affordances removed.
- This is not a confirmed fix for the reported delivery incident: the affected group and reproduction error remain needed. Failed sends do not yet have a durable retry outbox; existing groups with missing MLS state need recovery, not a cosmetic success state.

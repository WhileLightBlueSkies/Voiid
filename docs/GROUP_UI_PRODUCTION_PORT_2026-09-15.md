# Real iOS group UI port — 15 September 2026

The approved Voiid Ui layout is implemented in the real iOS app using existing APIs and real data:

- Centered encryption badge in ordinary and group conversations. Ordinary chats use SafetyNumberView; groups select a real member before opening the same identity-key verification screen. No sample codes or local preview group state.
- Real incoming group portraits, tappable public profiles, sender labels above the bubble, and bottom alignment independent of reactions.
- Group-info identity, call-action, settings-card and member-row layout, with real photos, roles, shared media and persisted mute durations. Voice/video use the chat's call-setup path.
- Add-member picker uses contact discovery and the existing MLS/server-roster operation. Errors propagate to the screen. Empty/malformed key packages fail before roster insertion; fan-out uses freshly fetched members. This does not make the multi-step roster/MLS mutation atomic.
- Roles remain server-enforced. Successful actions refresh the roster; removal and ownership transfer require confirmation.
- New-group name card, selected contact portraits, search and create button retain the existing server/MLS creation path.

## Not included in this port

Standalone-group description/photo editing, invite-link management, disappearing-message settings, and group mentions/replies notification preferences still need production backend support. The former no-op report/exit/invite controls are not presented as working actions. Safe self-leave still needs an MLS membership/rekey flow; the current engine rejects self-removal. These features were not replaced with local preview state.

No backend deployment or database changes were made for this port. Earlier notification deployment approval remains separate. No groups, invitations, messages or calls were created against other users during verification.

## Validation

The real iOS Debug device build passed, including the notification extension. The final build, including the avatar layout and real QR/digits verification layout, passed. Device installation is waiting for Nehal’s iPhone to reconnect. Live multi-account group flows still need device testing; compile success is not proof of delivery.

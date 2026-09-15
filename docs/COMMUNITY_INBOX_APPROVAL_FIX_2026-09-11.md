# Community inbox and membership approval flow

Community Inbox now opens a community-scoped request/moderation queue rather than personal host-message threads. Owners/admins can approve or decline pending requests. Reports remain visible with a direction to their existing moderation controls in Admin panel. The new queue does not create a conversation; explicit Message host and existing personal threads remain unchanged.

Approval commits membership before sending an applicant push to registered non-revoked devices. Duplicate approval of an already-active member does not send another push. Withdrawn/non-pending requests cannot be revived by stale approval actions. Community responses use Cache-Control: no-store.

Approval payloads use community_id and public community_handle, without conversation_id. Android uses the existing data-only FCM delivery and iOS uses an APNs alert without message NSE processing. While foregrounded both display the existing in-app capsule with a community destination; background notifications route to the community preview. The server remains the membership/access authority. Push delivery is best-effort, not a durable outbox; OS permission/network restrictions still apply.

Open community detail reloads on approval arrival; existing active-screen polling remains a fallback. QR/invite previews additionally revalidate pending state every five seconds while foregrounded, and replace stale pending status with Open community after approval. No new search is needed. The management inbox refreshes while foregrounded.

Backend deployed with backup /opt/voiid-backups/community-approval-20260911; health checked. No migration required. Payload tests: 13 passed. Native builds and real-device approval delivery must be checked independently; no real user's membership was modified for testing.

Final validation: iOS build and bundle verification passed; installed on Nehal’s iPhone 15. Android assembleDebug and 138 unit tests passed, zero failures/errors; phone disconnected, APK prepared at build/share/Voiid-Android-2026-09-11-community-inbox.apk. Real two-account approval/push testing remains pending.

## Manager notification follow-up

New pending join requests now notify active owners/admins after transaction commit. Repeating an already-pending join does not send another request alert. Approval notifications remain targeted to the applicant’s registered devices. Revoked devices are excluded. Push payloads contain community routing IDs, with no requester phone number or message content.

iOS now shows a foreground community capsule (previously the system notification was suppressed without displaying one). Android handles both request and approval types and ignores them while signed out. Taps open the relevant community preview; managers enter its separate Inbox to review requests. Push delivery remains best effort, with visible-screen polling as fallback.

Validation: backend TypeScript build and 14 push payload tests passed; Android build/unit tests passed. Backend deployed with rollback backup `/opt/voiid-backups/community-manager-20260911`; health reports API, database and Redis healthy. Latest Android APK: `build/share/Voiid-Android-2026-09-11-community-notifications.apk`. No Android device connected at validation time. Live two-account foreground/background notification delivery still needs device testing.

The iOS build passed after removing superseded generated APK copies to recover disk space; Firebase bundle verification passed. Installed on Nehal’s iPhone 15. Android: 138 unit tests, zero failures/errors.

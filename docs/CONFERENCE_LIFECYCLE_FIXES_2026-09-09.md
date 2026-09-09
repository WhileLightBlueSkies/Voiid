# Conference lifecycle follow-up — 9 September 2026

This follows the report that joining, leaving and ending conferences remain unreliable. The earlier build/test pass did not cover the failures below. These are confirmed code defects; the reported device session has not been reproduced or correlated with device logs.

## Changes

| Defect | Updated behavior |
| --- | --- |
| iOS immediately disconnected the entire room after one encryption failure, including during a membership key rotation. | Keep encryption enabled and allow eight seconds for recovery, independently per track. Healthy media or track removal cancels the watchdog. Persistent failure closes the room; an old room's watchdog cannot close a replacement. |
| Android controls still targeted the retired 1:1 engine after migration. | Mute, speaker, camera and camera switching target conference media. The call surface reflects conference control state; unsupported 1:1 hold is unavailable during a conference. Speaker selection survives handover. |
| Android elected the key coordinator from its local inviter while iOS used roster invitation history. | Both elect from the same shared roster, excluding invited/declined/left members as candidates. Android serializes key minting so an older async completion cannot overwrite a newer key. |
| Android relied on room events to refresh membership; a disconnect could arrive before the server processed Leave. | Poll the live roster every three seconds as well as reacting to events. Update membership and rotate keys after the server records a departure. |
| Declined rows matched every `state <> 'left'` query. | Only invited/joined members appear in live rosters, receive signaling grants or request tokens. Decline cannot be undone by a delayed Join; a fresh invitation is required. |
| Conversation membership let a departed original participant act as if still on the conference. | Once conference membership exists, it is authoritative. Admission rechecks joined membership while holding the call lock. |
| Join/Leave and call closure were not serialized together. | Use the same call-row lock for admission, joining, leaving and grant publication. A delayed Join cannot reopen a closed call or overwrite a completed decline/leave. |
| Pending invitations could keep an empty conference alive. | The last joined member leaving closes the call and cancels pending invitations. One member leaving while others remain preserves their conference. |
| Legacy 1:1 terminal status requests could close the shared conference. | Interpret those requests as participant leave once conference membership exists. The history UPDATE also refuses to globally terminate a conference. |
| An outsider's Leave could rewrite a live 1:1 grant as an empty conference grant. | Reject nonparticipant Leave without touching the grant. Repeated Leave by an actual participant remains idempotent. |
| Some abandoned conference invitations never reached the server leave path. | Native terminal cleanup releases the invitation, including push-originated and timed-out invitations. |
| iOS's alternate invite buttons bypassed the native call lifecycle. | Accept/Decline go through CallService. Duplicate conference join attempts are guarded. |
| A server-side accepted invitation was displayed as if media had connected. | Conference rosters show “Joining…” until the participant appears in the media room, and “Ringing…” while invited. Android permits adding another participant after migration. |

## Verification

- **84 server tests passed, none skipped**, including real PostgreSQL admission races and the new decline/reinvite, leave, last-member closure and forced delayed-join race scenarios.
- **26 focused native regression scenarios passed**: five existing CallKit end-handler cases; five Swift encryption recovery cases; five coordinator elections on each platform; three Android call-state races; three Android mute-routing cases. These execute extracted production methods with controlled dependencies, not real microphone or transport sessions.
- API TypeScript checking passed.
- Final iOS Debug device-target build passed with signing disabled. It was not installed on a phone.
- Final Android `:app:assembleDebug` passed. APK: `apps/android/app/build/outputs/apk/debug/app-debug.apk`; it was not installed on a phone.

Native regression commands:

```sh
python3 tools/check-call-lifecycle.py
python3 tools/check-android-call-state.py
python3 tools/check-conference-recovery.py
```

The PostgreSQL regressions use isolated local test databases through `CONF_TEST_DATABASE_URL` and `CALL_TEST_DATABASE_URL`. Do not point these tests at an application database.

## Device acceptance still required

Only two test devices were confirmed ready. No calls were placed, no app build was installed, and no backend was deployed during this follow-up. The installed app/backend versions that produced the reported problem remain unknown.

On updated clients and backend, run these with at least three separate test accounts:

1. Start iOS → Android and Android → iOS voice calls, add a participant, and verify audio both ways between every pair after handover.
2. Decline, ignore and accept an invite. During acceptance, cancel while fetching keys/token and while connecting to the room. Verify roster cleanup and that the originals keep talking.
3. Leave from the original caller, original callee and invitee in separate runs. Verify remaining participants keep audio after key rotation; mute/unmute and speaker controls still work.
4. Leave the final joined participant while another invitation is ringing. Verify the late answer is rejected and no client shows a connected empty call.
5. Add another participant after the original inviter has left, then leave/reinvite someone. Check both platforms agree on roster and media after each key update.
6. Repeat under Wi-Fi/mobile handover and packet loss; leave immediately before a pending join completes. Check that recovery does not end an unrelated replacement call.

See [the full QA matrix](CALL_QA_TEST_MATRIX.md) for platform, background and network permutations. These automated results do not certify three-device audio or push delivery.

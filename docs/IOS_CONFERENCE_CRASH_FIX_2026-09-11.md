# iOS conference selection crash and UI

Reported trigger: select a person in Add to call; app closes.

Found a deterministic bounds error in GroupCallScreen: max(participants.count, 1) created a tile for an empty roster, followed by participants[0]. Escalation exposed this screen before the room was connected. No fresh matching device crash report was available during inspection, so this is a confirmed unsafe code path consistent with the report, not a symbolicated diagnosis of that specific crash.

Changes:
- Keep the original 1:1 UI while escalating; transfer to conference UI after handover.
- Wait for the invite sheet's actual dismissal before escalation. No arbitrary animation delay.
- Latch invite selection and disable repeated add-person actions while upgrading.
- Show adding progress and existing service error messages.
- Empty roster has an explicit joining state; no invented tile.
- Render participant rows from a captured array and use participant identity rather than index for tile identity. Clamp tile dimensions for transient small layouts.
- Animate membership changes with the existing spring, respecting Reduce Motion.
- Ad-hoc room screens do not start conversation-backed joins with an empty conversation ID or dismiss the outer call UI on an intermediate room-idle state.

Device checks still required: add person, rapid repeated taps, picker cancellation, recipient decline/no answer, slow/failed upgrade preserving the original call, remote participant join/leave, final leave, video and rotation. Test with three separate accounts for full conference acceptance; only two test devices were previously confirmed available.

No encryption, invitation authorization, or backend conference membership rules changed.

Validation: final signed generic iOS device build succeeded; all four changed source files had rebuilt object files. Firebase bundle check passed after replacing the ignored nested stale plist with the existing valid in.voiid.app project configuration. Installed and launched on Nehal’s iPhone 15 on 11 September at approximately 13:47 IST. Live conference validation is not complete.

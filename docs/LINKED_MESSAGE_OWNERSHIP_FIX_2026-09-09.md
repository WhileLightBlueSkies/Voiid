# Linked-device message direction fix

A message sent from the browser reached the recipient correctly but appeared incoming on the sender's phone. Both native ChatEngine implementations decrypted sibling-device ciphertext with the correct sender identity, then constructed the stored message with `isMine = false`.

The native receive paths now derive direction from the account that authored the message. A different device on the same account remains a sent message. Device identity still selects the encryption session; encryption and backend sender authentication are unchanged.

Previously cached sibling messages are corrected for display immediately and persisted during the next successful sync, before decrypt-once dedup skips their IDs. The repair preserves message IDs, plaintext, quotes, media references, reactions and receipt timestamps; it never replays ciphertext or clears local storage. Receipt updates apply to already-seen sibling messages too. Own-account sync no longer emits incoming delivery/read receipts. Android also suppresses an own-message wake instead of falling back to a previous message from the peer.

## Regression checks

- `python3 tools/check-linked-message-ownership.py`: compiles the production Swift message types; verifies cache repair, JSON persistence, unchanged peer/unknown-account direction, and metadata preservation. Passed.
- Android `LinkedMessageOwnershipTest`: equivalent production-model and serialization cases. All four passed; Android debug build passed and was installed/launched on the connected CPH2745 without clearing data.
- Signed iOS build and Android debug build use an isolated snapshot of committed app source plus this fix, preserving other agents' uncommitted UI work. Both builds passed. The signed iPhone app and Android debug app were installed successfully on the connected test phones without clearing app data.

## Device verification

1. Send from linked web to another account: sender's iOS and Android phones show an outgoing bubble; the recipient shows incoming.
2. Reply from the recipient: sender phones and web show incoming.
3. Open a chat containing an old incorrectly displayed web message: it switches to outgoing without duplication; reopen/relaunch to check persistence.
4. Read the message on the recipient: sender phone ticks advance; opening it on the sender's sibling phone alone does not advance recipient read state.
5. Background Android: an own-browser send must not display a notification containing an older message from the peer.

Live account-level verification requires the user to send messages; automated checks do not send messages on their behalf.

## iPhone packaging correction

The first isolated iPhone package omitted the app-target `GoogleService-Info.plist`. Device crash reports identified a Firebase configure exception at startup. The correct configuration for `in.voiid.app` and the existing Firebase project was restored into the isolated app target, rebuilt, signature-checked and reinstalled. The repaired app remained running after launch (PID 16533 across repeated checks). `tools/check-ios-app-bundle.py` now checks the actual built app for the required configuration and bundle match before installation. No sign-out or data deletion was performed.

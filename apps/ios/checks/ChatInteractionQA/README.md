# Native chat interaction checks

The harness extracts the actual `MessageBubble` and `BubbleShape` from
`ChatDetailView.swift` and copies Voiid’s native context menu, reaction badges,
reaction helpers, emoji picker, voice player, recording bar, typography and colors.
Voice playback uses locally generated PCM audio; other media and network/account
services are stubbed. It does not install a demo route in Voiid,
use a real account, or send messages.

```sh
python3 apps/ios/checks/ChatInteractionQA/prepare.py
xcodegen generate --spec /private/tmp/voiid-chat-qa/project.yml
xcodebuild -project /private/tmp/voiid-chat-qa/ChatQA.xcodeproj \
  -scheme ChatQA -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/voiid-chat-qa-build \
  -parallel-testing-enabled NO test
```

Checks outgoing and incoming long presses, add/remove via reaction badges,
shared-emoji counts and ownership, Reply, the additional reaction palette,
full emoji sheet dismissal, incoming/outgoing swipe-to-reply, deleted-message
actions, and compact short/quoted message bounds.

Voice checks cover compact and larger-text bounds, 44-point controls, play/pause,
seeking without triggering reply, switching between notes, voice swipe-to-reply,
retry state and the recording bar’s delete action. Microphone capture and the full
hold/slide/release recording gesture still require device testing.

The independent reaction-data check uses production `MessageReactions.swift`:

```sh
xcrun swiftc apps/ios/Voiid/Voiid/Models/MessageReactions.swift \
  apps/ios/checks/MessageReactionsCheck.swift -o /private/tmp/voiid-reactions-check
/private/tmp/voiid-reactions-check
```

Device QA still needs two signed-in accounts to verify reaction delivery,
offline failure recovery, rapid replacement during sync, and media interactions.
This harness does not measure frame rates or network delivery.

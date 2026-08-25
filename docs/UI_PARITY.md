# Reference UI ↔ Voiid — screen-by-screen parity

Working checklist. Tick a row when its LOOK matches the reference.

Reference: `/Users/devacc/Voiid Ui/Voiid Ui/Voiid Ui/Chat/`
Voiid:     `apps/ios/Voiid/Voiid/`

**Voiid names things differently from the reference.** A file-name search says
half these screens are missing; they are not. This table is matched by FEATURE,
verified by reading, not by filename.

| Reference screen | Voiid file | Look matches? |
|---|---|---|
| ChatsScreen | `Main/ChatsHomeView.swift` | not checked |
| ConversationScreen | `Main/ChatDetailView.swift` | not checked |
| ChatSearchSheet | (search lives in ChatsHomeView) | not checked |
| ChatSettingsScreen | `Main/Settings/PreviewSettingsScreens.swift` → ChatSettingsScreen | preview only — no backend |
| NewChatSheet | `Main/NewChatView.swift` | not checked |
| CreateGroupSheet | `Main/NewGroupView.swift` | not checked |
| ContactScreen | `Main/ContactProfileView.swift` | not checked |
| ProfileSheet | `Main/Settings/SettingsSheet.swift` | **DONE** — card redesign |
| EditProfileScreen | `Main/Settings/EditProfileView.swift` | **DONE** — card redesign |
| SocialProfileScreen | `Main/Clips/CreatorProfileView.swift` | **DONE** — cover, counts, highlights |
| LinkedDevicesScreen | `Main/Settings/LinkedDevicesView.swift` | **DONE** — card redesign |
| ClipsScreen | `Main/Clips/ClipsFeedView.swift` + `MyClipsView` | **DONE** |
| MemoriesScreen | `Main/Stories/*` (Moments) | not checked |
| CommunitiesScreen | `Main/CommunitiesHomeView.swift` | not checked |
| CommunityHomeScreen | `Main/CommunityHomeTab.swift` | **DONE** |
| CommunityTabs | `Main/CommunityTabs.swift` | **DONE** |
| CommunityInboxScreen | `Main/CommunityInboxView.swift` | not checked |
| CommunityThreadScreen | `Main/CommunityInboxView.swift` (thread) | not checked |
| CreateCommunityFlow | `Main/CommunityCreateFlow.swift` | not checked |
| MessageCommunityScreen | `Main/MessageHostButton.swift` + host thread | not checked |
| GamesScreen | `Games/GamesHomeView.swift` | **DONE** — carousel + sections |
| GameDetailScreen | (no detail screen — setup sheet instead) | by design |
| GameLobbyScreen | `Games/GameLobbyView.swift` | not checked |
| GameInviteSheet | `Games/InviteBanner.swift` + `OpponentPickerSheet` | not checked |
| MatchStartingScreen | `Games/CoinSceneView.swift` / toss | not checked |
| FriendsMapScreen | `Main/MapTabView.swift` | **IN PROGRESS** |
| MapIntroScreen | `Main/MapIntroScreen.swift` | **DONE** |
| MapPrivacyScreen | `Main/MapPrivacyScreen.swift` | **DONE** |
| MapMoveScreen | `Main/MapMoveScreen.swift` | **DONE** |
| MapFlowScreen | `Main/MapOnboardingFlow.swift` | **DONE** |
| CallScreen | `Main/CallScreens.swift` | not checked |
| VideoCallScreen | `Main/CallScreens.swift` | not checked |
| GroupCallScreen | `Main/GroupCallScreen.swift` | not checked |
| GroupVideoCallScreen | `Main/GroupCallScreen.swift` | not checked |
| VoiceRecorder | `Main/VoiceRecorder*` / composer | not checked |
| RootTabView | `Main/RootTabView.swift` | not checked |
| ThreadResolvedScreen | (no equivalent) | by design |
| MessageSentScreen | (no equivalent) | by design |

## How to use this

Open a screen in the app, open its reference file, compare. When they match,
change the row to **DONE**. When they do not, say which screen and what is off —
that is faster than me guessing at all 38.

## The standing rule

Match the reference's LOOK. Do not import its DATA — it is a mockup with fake
friends, a hardcoded Toronto coordinate, a fake notification badge, battery
percentages and a V Coin balance. Voiid has none of those, and a beautiful
screen full of invented numbers is worse than a plain honest one.

See `docs/MAP_STATUS.md` for the same rule applied to the Map, plus the list of
reference elements deliberately not built.

# Android Parity Gaps

Android is not a thin port: chats, calls, reachability, maps, clips, stories, backup, and all game families have Kotlin implementations. It is still not parity-ready. P0 gaps are concentrated in onboarding/auth, restore, Communities, group-role handling, story capture, map audience management, and chat media/error states. The larger product-wide gap is interaction language: the audited Android tree still contains 23 Material `ModalBottomSheet` calls, 18 Material `AlertDialog` calls, and 17 raw Compose `Dialog` calls, but no `VoiidSheet` or `VoiidDialog`; navigation surfaces are generally opaque rather than material/translucent, pull-to-refresh is absent, and several iOS motion/haptic/error contracts were not ported. Core spacing and radius tokens are close, so shared custom Compose primitives will remove more divergence than screen-by-screen restyling.

## Summary table

| Area | Feature gap | Completeness gap | UI fidelity | Priority |
|---|---|---|---|---|
| App shell / navigation | None major | Ghost-state badge is missing | Opaque bar; wrong icon/indicator metrics and active scale | P1 |
| Onboarding / auth | Verified success screen missing | Dead OTP resend; weaker phone validation; no permission deferral | Major structural and motion divergence | P0 |
| Restore | Source chooser and staged restore missing | 4–8 digit PIN accepted instead of exactly 6; weaker retry/error feedback | Full-screen flow and hierarchy diverge | P0 |
| Chats / requests | Full-screen media viewer missing | Inbox load errors hidden; contact search absent in new-chat/group | Wrong sent-bubble color/text; composer/header differ | P0 |
| Calls | Core call flows exist | Self-preview drag lacks release velocity/cancel handling | Call-type and roster detents do not match | P1 |
| Profiles / groups | Safety-number QR missing | Android discards member roles; profile viewer never renders a photo | Missing pinch zoom; Material dialogs | P0 |
| Settings / privacy / backup | Account deletion route missing | Refresh, backup error, date, and logout confirmation gaps | Flattened hierarchy; full-screen dialog chaining | P1 |
| Communities | Create, host inbox, and four detail tabs missing | No refresh; create button is a no-op | Detail/cards far below iOS density and hierarchy | P0 |
| Moments | In-camera video capture missing | No refresh/delete menu; weak capture/upload errors | Reply is inline instead of a 260pt sheet | P0 |
| Map / live location | Cannot add audience members after initial share | Ghost duration chooser and stop-all confirmation missing | Custom header/control model differs | P0 |
| Clips | Core feed/camera/editor/profile flows exist | No refresh; library import can discard takes; weaker media processing | Material edit/handle sheets and delete dialog | P1 |
| Games | Online/bot game families exist | No screen-level feature gap found in inspected paths | Most setup/settings pickers are Material sheets; one stock `Switch` remains | P1 |
| AI | Core chat exists | None found in inspected path | Opaque chrome and no message insertion transition | P2 |
| Legal / consent / deep links | Core post-login consent and deep links exist | Onboarding consent gate is incomplete | Legal documents navigate inline instead of a sheet | P0 via onboarding |

## Gaps by area

### Screen / flow map

Component-only drawing helpers are excluded; every user-navigable screen, full-screen cover, sheet flow, and game mode is included.

#### Onboarding and legal

| iOS screen / flow | Android equivalent |
|---|---|
| `apps/ios/Voiid/Voiid/Onboarding/OnboardingFlow.swift:11-106` | `apps/android/app/src/main/java/com/voiid/app/onboarding/OnboardingFlow.kt:101-155` |
| Splash — `apps/ios/Voiid/Voiid/Onboarding/OnboardingFlow.swift:120-190` | `apps/android/app/src/main/java/com/voiid/app/onboarding/OnboardingFlow.kt:165-217` |
| Terms / consent — `apps/ios/Voiid/Voiid/Onboarding/WelcomeTermsScreen.swift:46-244` | `apps/android/app/src/main/java/com/voiid/app/onboarding/WelcomeTermsScreen.kt:70-229` |
| Legal document — `apps/ios/Voiid/Voiid/Legal/LegalDocumentView.swift:18` | `apps/android/app/src/main/java/com/voiid/app/main/LegalDocumentScreen.kt:37` |
| Phone — `apps/ios/Voiid/Voiid/Onboarding/PhoneScreen.swift:42-230` | `apps/android/app/src/main/java/com/voiid/app/onboarding/PhoneScreen.kt:76-310` |
| Country picker — `apps/ios/Voiid/Voiid/Onboarding/CountryPickerSheet.swift:31-155` | `apps/android/app/src/main/java/com/voiid/app/onboarding/CountryPickerSheet.kt:58-169` |
| OTP — `apps/ios/Voiid/Voiid/Onboarding/OTPScreen.swift:36-425` | `apps/android/app/src/main/java/com/voiid/app/onboarding/OtpScreen.kt:48-165` |
| Restore unlock / phrase / source / progress — `apps/ios/Voiid/Voiid/Onboarding/RestoreMessagesView.swift:48-670` | `apps/android/app/src/main/java/com/voiid/app/onboarding/RestoreFlow.kt:50-232` — partial |
| Verified — `apps/ios/Voiid/Voiid/Onboarding/VerifiedScreen.swift:36-180` | **MISSING** |
| Identity profile — `apps/ios/Voiid/Voiid/Onboarding/SignupScreen.swift:51-365` | split/reordered across `apps/android/app/src/main/java/com/voiid/app/onboarding/SignupScreen.kt:35-81` and `apps/android/app/src/main/java/com/voiid/app/onboarding/CreateProfileScreen.kt:58-239` |
| Optional profile details — `apps/ios/Voiid/Voiid/Onboarding/CreateProfileScreen.swift:35-227` | split/reordered across the same two Android files; no equivalent optional step |
| Permissions — `apps/ios/Voiid/Voiid/Onboarding/PermissionsScreen.swift:45-203` | `apps/android/app/src/main/java/com/voiid/app/onboarding/PermissionsScreen.kt:69-227` |
| Existing-account consent backfill — `apps/ios/Voiid/Voiid/Legal/ConsentPromptView.swift:27-110` | `apps/android/app/src/main/java/com/voiid/app/main/ConsentPromptScreen.kt:67` |
| Required update cover — `apps/ios/Voiid/Voiid/Networking/ConfigService.swift:59-61` | `apps/android/app/src/main/java/com/voiid/app/MainActivity.kt:331-340` |

#### Shell, messaging, calling, and profiles

| iOS screen / flow | Android equivalent |
|---|---|
| Seven-tab shell — `apps/ios/Voiid/Voiid/Main/RootTabView.swift:41-445` | `apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:101-1061` |
| AI chat — `apps/ios/Voiid/Voiid/Main/AIChatView.swift:12-86` | `apps/android/app/src/main/java/com/voiid/app/main/AIChatView.kt:52-154` |
| Chats home / grid — `apps/ios/Voiid/Voiid/Main/ChatsHomeView.swift:11-875` | `apps/android/app/src/main/java/com/voiid/app/main/ChatsHomeView.kt:128-1050` |
| Call history — `apps/ios/Voiid/Voiid/Main/CallLogView.swift:21-300` | `apps/android/app/src/main/java/com/voiid/app/main/CallLogScreen.kt:79-358` |
| Find by username — `apps/ios/Voiid/Voiid/Main/FindByUsernameView.swift:23-204` | `apps/android/app/src/main/java/com/voiid/app/main/ReachabilityScreens.kt:76-245` |
| Message requests — `apps/ios/Voiid/Voiid/Main/MessageRequestsView.swift:20-166` | `apps/android/app/src/main/java/com/voiid/app/main/ReachabilityScreens.kt:260-384` |
| New chat — `apps/ios/Voiid/Voiid/Main/NewChatView.swift:13-159` | `apps/android/app/src/main/java/com/voiid/app/main/NewChatScreen.kt:59-197` |
| New group — `apps/ios/Voiid/Voiid/Main/NewGroupView.swift:13-183` | `apps/android/app/src/main/java/com/voiid/app/main/NewGroupScreen.kt:67-220` |
| Chat detail — `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:20-1931` | `apps/android/app/src/main/java/com/voiid/app/main/ChatDetailView.kt:103-730` plus `apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt` |
| Forward, message info, poll compose — `apps/ios/Voiid/Voiid/Main/ForwardSheet.swift:10`, `apps/ios/Voiid/Voiid/Main/MessageInfoSheet.swift:11`, `apps/ios/Voiid/Voiid/Main/PollComposeSheet.swift:10` | combined in `apps/android/app/src/main/java/com/voiid/app/main/ChatSheets.kt:108-271` |
| GIF / emoji pickers — `apps/ios/Voiid/Voiid/Main/GifPickerSheet.swift:21`, `apps/ios/Voiid/Voiid/Main/EmojiPickerSheet.swift:11` | `apps/android/app/src/main/java/com/voiid/app/main/GifPickerSheet.kt:78`, `apps/android/app/src/main/java/com/voiid/app/main/EmojiPickerSheet.kt:46` |
| Location compose / detail — `apps/ios/Voiid/Voiid/Main/LocationComposeSheet.swift:19`, `apps/ios/Voiid/Voiid/Main/LocationDetailView.swift:30` | `apps/android/app/src/main/java/com/voiid/app/main/LocationSheets.kt:72`, `apps/android/app/src/main/java/com/voiid/app/main/LocationDetailView.kt:85` |
| Full-screen message image — `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:1920-1931` | **MISSING** |
| Contact profile — `apps/ios/Voiid/Voiid/Main/ContactProfileView.swift:18-867` | `apps/android/app/src/main/java/com/voiid/app/main/ContactProfileView.kt:98-996` |
| Group info / member administration — `apps/ios/Voiid/Voiid/Main/GroupInfoView.swift:12-293` | `apps/android/app/src/main/java/com/voiid/app/main/GroupInfoView.kt:68-324` — partial |
| Shared media — `apps/ios/Voiid/Voiid/Main/SharedMediaSheet.swift:11-140` | `apps/android/app/src/main/java/com/voiid/app/main/SharedMediaSheet.kt:73` |
| Safety number — `apps/ios/Voiid/Voiid/Main/SafetyNumberView.swift:34-300` | `apps/android/app/src/main/java/com/voiid/app/main/SafetyNumberScreen.kt:75-300` — no QR |
| Report — `apps/ios/Voiid/Voiid/Main/ReportSheet.swift:26` | `apps/android/app/src/main/java/com/voiid/app/main/ReportSheet.kt:44` |
| Call type / 1:1 call — `apps/ios/Voiid/Voiid/Main/CallScreens.swift:64-867` | `apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt:117-1064` |
| Group call — `apps/ios/Voiid/Voiid/Main/GroupCallScreen.swift:20-450` | `apps/android/app/src/main/java/com/voiid/app/main/GroupCallScreens.kt:78-400` |
| Group-call roster — `apps/ios/Voiid/Voiid/Main/GroupCallRosterSheet.swift:27-110` | `apps/android/app/src/main/java/com/voiid/app/main/GroupCallRosterSheet.kt:57-130` |
| Conference invite / roster — `apps/ios/Voiid/Voiid/Main/ConferenceViews.swift:33-205` | `apps/android/app/src/main/java/com/voiid/app/main/ConferenceViews.kt:74-210` |
| Ongoing call / PiP — `apps/ios/Voiid/Voiid/Main/OngoingCallBanner.swift:28`, `apps/ios/Voiid/Voiid/Main/CallPiPView.swift:18` | `apps/android/app/src/main/java/com/voiid/app/main/OngoingCallBanner.kt`, `apps/android/app/src/main/java/com/voiid/app/main/CallPip.kt` |

#### Settings

| iOS screen / flow | Android equivalent |
|---|---|
| Settings root — `apps/ios/Voiid/Voiid/Main/Settings/SettingsSheet.swift:223-760` | `apps/android/app/src/main/java/com/voiid/app/main/SettingsScreen.kt:95-680` |
| Edit profile / account deletion — `apps/ios/Voiid/Voiid/Main/Settings/EditProfileView.swift:46-406` | inline partial editor in `apps/android/app/src/main/java/com/voiid/app/main/SettingsScreen.kt:109-208`; deletion **MISSING** |
| Privacy / contact PIN / map visibility — `apps/ios/Voiid/Voiid/Main/Settings/PrivacySettingsView.swift:45-420` | `apps/android/app/src/main/java/com/voiid/app/main/PrivacySettingsScreen.kt:64-455` |
| Blocked contacts — `apps/ios/Voiid/Voiid/Main/Settings/BlockedContactsView.swift:25-175` | `apps/android/app/src/main/java/com/voiid/app/main/BlockedContactsScreen.kt:65-230` |
| Linked devices — `apps/ios/Voiid/Voiid/Main/Settings/LinkedDevicesView.swift:37-430` | `apps/android/app/src/main/java/com/voiid/app/main/LinkedDevicesScreen.kt:58-210` |
| Storage — `apps/ios/Voiid/Voiid/Main/Settings/StorageSettingsView.swift:35-220` | `apps/android/app/src/main/java/com/voiid/app/main/StorageSettingsScreen.kt:51-192` |
| Backup and recovery — `apps/ios/Voiid/Voiid/Main/Settings/BackupRecoveryView.swift:15-283` | `apps/android/app/src/main/java/com/voiid/app/main/BackupRecoveryScreen.kt:70-299` |
| Backup setup / recovery phrase / PIN change — `apps/ios/Voiid/Voiid/Main/Settings/BackupRecoveryView.swift:306-440` | private full-screen branches in `apps/android/app/src/main/java/com/voiid/app/main/BackupRecoveryScreen.kt:303-620` |
| About — `apps/ios/Voiid/Voiid/Main/Settings/AboutView.swift:53-220` | `apps/android/app/src/main/java/com/voiid/app/main/AboutScreen.kt:57-188` |
| Legal / consent withdrawal — `apps/ios/Voiid/Voiid/Main/Settings/LegalView.swift:28-110` | `apps/android/app/src/main/java/com/voiid/app/main/LegalScreen.kt:73-240` |
| My QR, share profile, account center, encryption status, account, chat settings, Voiid One, payments, help — `apps/ios/Voiid/Voiid/Main/Settings/PreviewSettingsScreens.swift:100-305` | **MISSING**; these iOS routes are explicitly preview/unwired, so keep below live P0 work |

#### Communities, map, Moments, and Clips

| iOS screen / flow | Android equivalent |
|---|---|
| Communities home/search — `apps/ios/Voiid/Voiid/Main/CommunitiesHomeView.swift:24-371` | `apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt:46-168` |
| Five-step create — `apps/ios/Voiid/Voiid/Main/CommunityCreateFlow.swift:140-689` | **MISSING** |
| Community detail shell — `apps/ios/Voiid/Voiid/Main/CommunityDetailView.swift:15-423` | `apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt:193-266` — partial |
| Community Home tab — `apps/ios/Voiid/Voiid/Main/CommunityHomeTab.swift:20-335` | **MISSING** |
| Spaces tab — `apps/ios/Voiid/Voiid/Main/CommunityTabs.swift:49-274` | **MISSING** |
| Events / tournaments — `apps/ios/Voiid/Voiid/Main/CommunityEventsSection.swift:20`, `apps/ios/Voiid/Voiid/Main/CommunityTournamentsSection.swift:22` | `apps/android/app/src/main/java/com/voiid/app/main/CommunityEventsSection.kt:52`, `apps/android/app/src/main/java/com/voiid/app/main/CommunityTournamentsSection.kt:52` |
| Members tab — `apps/ios/Voiid/Voiid/Main/CommunityTabs.swift:276-535` | **MISSING** |
| About tab — `apps/ios/Voiid/Voiid/Main/CommunityTabs.swift:537-816` | **MISSING** |
| Host inbox — `apps/ios/Voiid/Voiid/Main/CommunityInboxView.swift:30-307` | **MISSING** |
| Invite-link join — `apps/ios/Voiid/Voiid/Main/CommunityJoinSheet.swift:32-210` | `apps/android/app/src/main/java/com/voiid/app/main/CommunityJoinSheet.kt:69-190` |
| Message host — `apps/ios/Voiid/Voiid/Main/MessageHostButton.swift:42-132` | `apps/android/app/src/main/java/com/voiid/app/main/MessageHostButton.kt:70-166` |
| Map / ghost mode — `apps/ios/Voiid/Voiid/Main/MapTabView.swift:28-350` | `apps/android/app/src/main/java/com/voiid/app/main/MapTabView.kt:89-590` |
| Map explainer — `apps/ios/Voiid/Voiid/Main/MapAudienceSheet.swift:289-348` | inline `apps/android/app/src/main/java/com/voiid/app/main/MapTabView.kt:534-590` |
| Map audience picker/list — `apps/ios/Voiid/Voiid/Main/MapAudienceSheet.swift:20-286` | `apps/android/app/src/main/java/com/voiid/app/main/MapAudienceSheet.kt:71-335` — partial |
| Map pin / location detail — `apps/ios/Voiid/Voiid/Main/LocationPinBubble.swift:67-272`, `apps/ios/Voiid/Voiid/Main/LocationDetailView.swift:30` | `apps/android/app/src/main/java/com/voiid/app/main/LocationViews.kt`, `apps/android/app/src/main/java/com/voiid/app/main/LocationDetailView.kt:85` |
| Moments home — `apps/ios/Voiid/Voiid/Main/Stories/StoriesHomeView.swift:16-190` | `apps/android/app/src/main/java/com/voiid/app/main/stories/StoriesHomeView.kt:50-172` |
| Composer — `apps/ios/Voiid/Voiid/Main/Stories/StoryComposerView.swift:20-214` | `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryComposerSheet.kt:76-270` |
| Camera — `apps/ios/Voiid/Voiid/Main/Stories/StoryCameraView.swift:33-160` | `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryCameraView.kt:49-123` — photo-only |
| Audience picker — `apps/ios/Voiid/Voiid/Main/Stories/StoryAudiencePickerView.swift:16-84` | `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryAudiencePicker.kt:51-120` |
| Viewer / reply — `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift:22-390` | `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewerView.kt:82-381` — reply presentation differs |
| Viewer list — `apps/ios/Voiid/Voiid/Main/Stories/StoryViewersSheet.swift:13-76` | `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewersSheet.kt:37-90` |
| Clips explore/following — `apps/ios/Voiid/Voiid/Main/Clips/ClipsFeedView.swift:14-541` | `apps/android/app/src/main/java/com/voiid/app/main/clips/ClipsFeedView.kt:66-520` |
| Clip fullscreen pager — `apps/ios/Voiid/Voiid/Main/Clips/ClipFullscreenView.swift:25-760` | `apps/android/app/src/main/java/com/voiid/app/main/clips/ClipFullscreenView.kt:242-730` |
| Clip capture / takes — `apps/ios/Voiid/Voiid/Main/Clips/ClipCameraView.swift:66-1100` | `apps/android/app/src/main/java/com/voiid/app/main/clips/ClipCameraView.kt:119-798` |
| Clip compose / details — `apps/ios/Voiid/Voiid/Main/Clips/ClipComposerFlow.swift:25-243` | `apps/android/app/src/main/java/com/voiid/app/main/clips/ClipComposerFlow.kt:78-314` |
| Clip editor — `apps/ios/Voiid/Voiid/Main/Clips/ClipEditor.swift:146-650` | `apps/android/app/src/main/java/com/voiid/app/main/clips/ClipEditor.kt:355-780` |
| Creator handle — `apps/ios/Voiid/Voiid/Main/Clips/CreatorHandleSheet.swift:19-130` | `apps/android/app/src/main/java/com/voiid/app/main/clips/CreatorHandleSheet.kt:71-150` |
| Creator profile / edit — `apps/ios/Voiid/Voiid/Main/Clips/CreatorProfileView.swift:21-630` | `apps/android/app/src/main/java/com/voiid/app/main/clips/CreatorProfileView.kt:88-560` |
| My clips / edit — `apps/ios/Voiid/Voiid/Main/Clips/MyClipsView.swift:17-270` | `apps/android/app/src/main/java/com/voiid/app/main/clips/MyClipsView.kt:81-350` |

#### Games

| iOS screen / flow | Android equivalent |
|---|---|
| Games home / invites — `apps/ios/Voiid/Voiid/Games/GamesHomeView.swift:25-601` | `apps/android/app/src/main/java/com/voiid/app/main/games/GamesHomeScreen.kt:81-339` |
| Daily challenge / leaderboard — `apps/ios/Voiid/Voiid/Games/DailyChallengeView.swift:30`, `apps/ios/Voiid/Voiid/Games/LeaderboardView.swift:21` | `apps/android/app/src/main/java/com/voiid/app/main/games/DailyChallengeScreen.kt:71`, `apps/android/app/src/main/java/com/voiid/app/main/games/LeaderboardScreen.kt:64` |
| Settings / snake skin — `apps/ios/Voiid/Voiid/Games/GameSettingsSheet.swift:25`, `apps/ios/Voiid/Voiid/Games/SnakeSkinPicker.swift:130` | `apps/android/app/src/main/java/com/voiid/app/main/games/GameSettingsSheet.kt:63`, `apps/android/app/src/main/java/com/voiid/app/main/games/SnakeSkinPicker.kt:138` |
| Setup / opponent / overs / duel / seat — `apps/ios/Voiid/Voiid/Games/GameSetupSheet.swift:21`, `apps/ios/Voiid/Voiid/Games/OpponentPickerSheet.swift:17`, `apps/ios/Voiid/Voiid/Games/OversSheet.swift:20`, `apps/ios/Voiid/Voiid/Games/DuelSheet.swift:28`, `apps/ios/Voiid/Voiid/Games/SeatPickerSheet.swift:24` | matching files under `apps/android/app/src/main/java/com/voiid/app/main/games/`: `apps/android/app/src/main/java/com/voiid/app/main/games/GameSetupSheet.kt:73`, `apps/android/app/src/main/java/com/voiid/app/main/games/OpponentPickerSheet.kt:43`, `apps/android/app/src/main/java/com/voiid/app/main/games/OversSheet.kt:42`, `apps/android/app/src/main/java/com/voiid/app/main/games/DuelSheet.kt:48`, `apps/android/app/src/main/java/com/voiid/app/main/games/SeatPickerSheet.kt:60` |
| Lobby — `apps/ios/Voiid/Voiid/Games/GameLobbyView.swift:37` | `apps/android/app/src/main/java/com/voiid/app/main/games/GameLobbyScreen.kt:99` |
| Tic-tac-toe online / bot — `apps/ios/Voiid/Voiid/Games/TicTacToeView.swift:19`, `apps/ios/Voiid/Voiid/Games/TicTacToeBotView.swift:16` | `apps/android/app/src/main/java/com/voiid/app/main/games/TicTacToeScreen.kt:50`, `apps/android/app/src/main/java/com/voiid/app/main/games/TicTacToeBotScreen.kt:80` |
| Rock-paper-scissors online / bot — `apps/ios/Voiid/Voiid/Games/RpsMatchView.swift:31`, `apps/ios/Voiid/Voiid/Games/RpsBotView.swift:18` | `apps/android/app/src/main/java/com/voiid/app/main/games/RpsMatchScreen.kt:76`, `apps/android/app/src/main/java/com/voiid/app/main/games/RpsBotScreen.kt:72` |
| Hand cricket online / bot — `apps/ios/Voiid/Voiid/Games/CricketMatchView.swift:23`, `apps/ios/Voiid/Voiid/Games/CricketBotView.swift:24` | `apps/android/app/src/main/java/com/voiid/app/main/games/CricketMatchScreen.kt:65`, `apps/android/app/src/main/java/com/voiid/app/main/games/CricketBotScreen.kt:90` |
| Sea Battle online / bot — `apps/ios/Voiid/Voiid/Games/SeaBattleView.swift:18`, `apps/ios/Voiid/Voiid/Games/SeaBattleBotView.swift:21` | `apps/android/app/src/main/java/com/voiid/app/main/games/SeaBattleScreen.kt:59`, `apps/android/app/src/main/java/com/voiid/app/main/games/SeaBattleBotScreen.kt:58` |
| Ludo online / bot — `apps/ios/Voiid/Voiid/Games/LudoView.swift:17`, `apps/ios/Voiid/Voiid/Games/LudoBotView.swift:20` | `apps/android/app/src/main/java/com/voiid/app/main/games/LudoScreen.kt:72`, `apps/android/app/src/main/java/com/voiid/app/main/games/LudoBotScreen.kt:53` |
| Snake arena — `apps/ios/Voiid/Voiid/Games/SnakeArenaView.swift:25` | `apps/android/app/src/main/java/com/voiid/app/main/games/SnakeArenaScreen.kt:94` |
| Shared match-end result — `apps/ios/Voiid/Voiid/Games/MatchEndOverlay.swift:29` | `apps/android/app/src/main/java/com/voiid/app/main/games/MatchEndOverlay.kt:95` |

#### Android-only or differently factored surfaces

| Android surface | iOS pairing |
|---|---|
| `apps/android/app/src/main/java/com/voiid/app/main/ReachabilityScreens.kt:76-384` combines username lookup and requests | two separate iOS files listed above |
| `apps/android/app/src/main/java/com/voiid/app/main/ChatSheets.kt:108-271` combines three sheets | three separate iOS files listed above |
| `apps/android/app/src/main/java/com/voiid/app/main/CallRingBanner.kt` | global incoming `CallScreen` cover in `apps/ios/Voiid/Voiid/ContentView.swift:68-76` |
| `apps/android/app/src/main/java/com/voiid/app/main/MapUnavailableCard.kt` | inline Map states in `apps/ios/Voiid/Voiid/Main/MapTabView.swift` |
| `apps/android/app/src/main/java/com/voiid/app/main/GroupCallScreens.kt:78` uses a root overlay | `apps/ios/Voiid/Voiid/Main/GroupCallScreen.swift:20` full-screen view |
| `apps/android/app/src/main/java/com/voiid/app/MainActivity.kt:331-340` update-required page | `apps/ios/Voiid/Voiid/Networking/ConfigService.swift:59-61` full-screen cover |

### App shell and navigation

**iOS:** `apps/ios/Voiid/Voiid/Main/RootTabView.swift:111-167,260-445`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:280-365,834-1061`

- **Partial:** Android shows the Map visibility dot only while visible; iOS swaps to a hollow `moon.zzz.fill` badge while ghosted (`apps/ios/Voiid/Voiid/Main/RootTabView.swift:415-431` vs `apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:1036-1047`). Add the persistent ghost-state glyph.
- **UI mismatch:** Android uses `background` at 98% opacity; iOS uses `.bar` material blur plus a 0.5pt divider (`apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:858-864` vs `apps/ios/Voiid/Voiid/Main/RootTabView.swift:267-274`). Build a translucent custom navigation surface; do not replace it with Material NavigationBar.
- **UI mismatch:** Android indicator is 20×3dp and icon is 24dp; iOS is 22×3pt and 22pt (`apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:917-935,1027-1033` vs `apps/ios/Voiid/Voiid/Main/RootTabView.swift:337-355`). Match 22/22.
- **UI mismatch:** Android's “active pop” animates inactive icons to 0.94 and active icons to 1.0, despite the comment promising 1.10; iOS actually drives 1.10 while sliding (`apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:987-996` vs `apps/ios/Voiid/Voiid/Main/RootTabView.swift:362-371`). Implement a transient 1.10 selection phase, then settle to 1.0.
- **UI mismatch:** Page crossfade duration already matches at 180ms (`apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:291-299` vs `apps/ios/Voiid/Voiid/Main/RootTabView.swift:138-143`); preserve it in the custom nav refactor.

### Onboarding: consent and handoff

**iOS:** `apps/ios/Voiid/Voiid/Onboarding/WelcomeTermsScreen.swift:58-108,171-244`; `apps/ios/Voiid/Voiid/Onboarding/OnboardingFlow.swift:43-106`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/onboarding/WelcomeTermsScreen.kt:60-88,170-187`; `apps/android/app/src/main/java/com/voiid/app/onboarding/OnboardingFlow.kt:76-217`

- **Missing:** Android has no explicit consent checkbox or disabled Continue state; the CTA itself is treated as consent (`apps/android/app/src/main/java/com/voiid/app/onboarding/WelcomeTermsScreen.kt:60-67,170-175`). Port the 26pt checkbox, 8pt radius, 2pt stroke, selection haptic, and disabled gate from iOS (`apps/ios/Voiid/Voiid/Onboarding/WelcomeTermsScreen.swift:171-244`).
- **Partial:** iOS presents six legal documents in a sheet; Android exposes four and swaps the screen inline (`apps/ios/Voiid/Voiid/Onboarding/WelcomeTermsScreen.swift:104-108,267-312` vs `apps/android/app/src/main/java/com/voiid/app/onboarding/WelcomeTermsScreen.kt:79-88,221-229`). Restore the full document set and sheet presentation.
- **UI mismatch:** Android reintroduces “I already have an account”; iOS explicitly removed that branch (`apps/android/app/src/main/java/com/voiid/app/onboarding/OnboardingFlow.kt:145-148`, `apps/android/app/src/main/java/com/voiid/app/onboarding/WelcomeTermsScreen.kt:178-187` vs `apps/ios/Voiid/Voiid/Onboarding/WelcomeTermsScreen.swift:171-177`). Remove it unless product changes the iOS reference.
- **UI mismatch:** Android splash waits 1900ms and animates a 500ms shared-element/crossfade; iOS waits 1.2s and deliberately has no handoff animation (`apps/android/app/src/main/java/com/voiid/app/onboarding/OnboardingFlow.kt:113-140` vs `apps/ios/Voiid/Voiid/Onboarding/OnboardingFlow.swift:43-66`). Match 1200ms and the hard handoff.
- **UI mismatch:** Android renders a text `"voiid"` placeholder mark; iOS renders `VoiidMark`/brand wordmark (`apps/android/app/src/main/java/com/voiid/app/onboarding/OnboardingFlow.kt:194-217` vs `apps/ios/Voiid/Voiid/Onboarding/OnboardingFlow.swift:169-190`). Use the real vector brand asset.

### OTP, phone, country, and verification

**iOS:** `apps/ios/Voiid/Voiid/Onboarding/PhoneScreen.swift:58-173`; `apps/ios/Voiid/Voiid/Onboarding/OTPScreen.swift:36-425`; `apps/ios/Voiid/Voiid/Onboarding/VerifiedScreen.swift:36-180`; `apps/ios/Voiid/Voiid/Onboarding/CountryPickerSheet.swift:31-155`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/onboarding/PhoneScreen.kt:76-310`; `apps/android/app/src/main/java/com/voiid/app/onboarding/OtpScreen.kt:48-165`; `apps/android/app/src/main/java/com/voiid/app/onboarding/CountryPickerSheet.kt:58-169`; Verified **MISSING**

- **Missing:** OTP “Resend” only fires a tap haptic; it does not call auth, replace the verification ID, clear the code, restart a countdown, or refocus (`apps/android/app/src/main/java/com/voiid/app/onboarding/OtpScreen.kt:153-165`). Port iOS resend behavior (`apps/ios/Voiid/Voiid/Onboarding/OTPScreen.swift:336-385`).
- **Missing:** Android skips the Verified success screen entirely. Port the 116pt ring, 4pt stroke, 54×40 tick with 7pt stroke, 450/300/500/750/350ms staged motion, 1.1s hold, success haptic, and reduced-motion branch (`apps/ios/Voiid/Voiid/Onboarding/VerifiedScreen.swift:75-180`).
- **Partial:** Android phone validity is only `digits.length >= 6`; iOS applies country min/max length, dial-code/trunk normalization, clears/refocuses on country change, and caps input (`apps/android/app/src/main/java/com/voiid/app/onboarding/PhoneScreen.kt:95-123,305-310` vs `apps/ios/Voiid/Voiid/Onboarding/PhoneScreen.swift:58-86,156-173`). Port per-country validation and focus behavior.
- **Partial:** Android OTP lacks countdown/expiry UI, change-number path, and one-time-code autofill semantics (`apps/android/app/src/main/java/com/voiid/app/onboarding/OtpScreen.kt:120-165` vs `apps/ios/Voiid/Voiid/Onboarding/OTPScreen.swift:133-140,187,255-297`).
- **Partial:** Android country search matches name/dial only and never scrolls to the current selection; iOS also matches exact ISO and centers the selected country (`apps/android/app/src/main/java/com/voiid/app/onboarding/CountryPickerSheet.kt:67-71,104-169` vs `apps/ios/Voiid/Voiid/Onboarding/CountryPickerSheet.swift:42-53,121-155`).
- **UI mismatch:** Android uses tap feedback for verification errors and has no `error()` haptic API (`apps/android/app/src/main/java/com/voiid/app/onboarding/OtpScreen.kt:93-97`; `apps/android/app/src/main/java/com/voiid/app/ui/components/Haptics.kt:28-117`). Add the iOS error notification contract (`apps/ios/Voiid/Voiid/DesignSystem/Haptics.swift:31-33`).

### Restore

**iOS:** `apps/ios/Voiid/Voiid/Onboarding/RestoreMessagesView.swift:48-178,184-270,403-485,594-670`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/onboarding/RestoreFlow.kt:45-232`

- **Missing:** Android has only `LANDING`, `PIN`, and `PHRASE`; iOS also has source choice and staged restoring states (`apps/android/app/src/main/java/com/voiid/app/onboarding/RestoreFlow.kt:47-65` vs `apps/ios/Voiid/Voiid/Onboarding/RestoreMessagesView.swift:53-100`). Add candidate selection when more than one backup exists and the five named progress stages.
- **Partial:** Android accepts 4–8 digits; iOS PIN is exactly 6 (`apps/android/app/src/main/java/com/voiid/app/onboarding/RestoreFlow.kt:117-133` vs `apps/ios/Voiid/Voiid/Onboarding/RestoreMessagesView.swift:192-196`). Enforce six digits across setup and restore.
- **Partial:** Android restores from server immediately or signs into Drive manually; iOS loads all available destinations, selects the newest, handles an empty candidate race, and lets the user choose (`apps/android/app/src/main/java/com/voiid/app/onboarding/RestoreFlow.kt:70-90,105-158` vs `apps/ios/Voiid/Voiid/Onboarding/RestoreMessagesView.swift:109-131,403-485`). Port platform-appropriate server/Drive candidate ordering; omit iCloud on Android.
- **Partial:** Android keeps failures inside PIN/phrase pages and has no stage-level Retry/Skip state or success hold; iOS surfaces errors on the restoring page, fires error/success haptics, and holds completion for 650ms (`apps/android/app/src/main/java/com/voiid/app/onboarding/RestoreFlow.kt:92-158` vs `apps/ios/Voiid/Voiid/Onboarding/RestoreMessagesView.swift:134-170,623-658`).
- **UI mismatch:** iOS uses the dark onboarding visual system with pinned footer and six separate PIN boxes; Android uses the settings backup scaffold (`apps/ios/Voiid/Voiid/Onboarding/RestoreMessagesView.swift:198-260` vs `apps/android/app/src/main/java/com/voiid/app/onboarding/RestoreFlow.kt:162-232`). Reuse Android onboarding primitives, not settings primitives.

### Permissions and profile creation

**iOS:** `apps/ios/Voiid/Voiid/Onboarding/PermissionsScreen.swift:45-203`; `apps/ios/Voiid/Voiid/Onboarding/SignupScreen.swift:51-365`; `apps/ios/Voiid/Voiid/Onboarding/CreateProfileScreen.swift:35-227`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/onboarding/PermissionsScreen.kt:69-227`; `apps/android/app/src/main/java/com/voiid/app/onboarding/SignupScreen.kt:35-81`; `apps/android/app/src/main/java/com/voiid/app/onboarding/CreateProfileScreen.kt:58-239`

- **Missing:** Android has no “Not now” permission path (`apps/android/app/src/main/java/com/voiid/app/onboarding/PermissionsScreen.kt:163-170`); iOS supports Allow All and deferral (`apps/ios/Voiid/Voiid/Onboarding/PermissionsScreen.swift:95-120`). Add a non-blocking defer action.
- **UI mismatch:** Android adds chevrons to noninteractive permission rows and changes order/copy; iOS rows are informational with no chevrons and use Location, Notifications, Camera, Microphone, Photos, Contacts (`apps/android/app/src/main/java/com/voiid/app/onboarding/PermissionsScreen.kt:189-227` vs `apps/ios/Voiid/Voiid/Onboarding/PermissionsScreen.swift:65-83,175-203`).
- **Missing:** Android's first profile step is name + required email; iOS requires photo/name/username and checks username availability with a 400ms debounce (`apps/android/app/src/main/java/com/voiid/app/onboarding/SignupScreen.kt:35-81` vs `apps/ios/Voiid/Voiid/Onboarding/SignupScreen.swift:51-84,128-200,261-348`). Align the data contract and server validation.
- **Partial:** Android username validation only checks length ≥3; iOS enforces 3–20 characters and rejects a leading digit (`apps/android/app/src/main/java/com/voiid/app/onboarding/CreateProfileScreen.kt:64-86` vs `apps/ios/Voiid/Voiid/Onboarding/SignupScreen.swift:68-84`).
- **Missing:** iOS's second step has optional email/bio, privacy copy, and “Skip for now”; Android has no equivalent optional step and makes email mandatory earlier (`apps/ios/Voiid/Voiid/Onboarding/CreateProfileScreen.swift:35-188` vs `apps/android/app/src/main/java/com/voiid/app/onboarding/SignupScreen.kt:35-81`).

### Chats home, new chat, and requests

**iOS:** `apps/ios/Voiid/Voiid/Main/ChatsHomeView.swift:57-75,214-314,365-450`; `apps/ios/Voiid/Voiid/Main/NewChatView.swift:58-94`; `apps/ios/Voiid/Voiid/Main/NewGroupView.swift:24-107`; `apps/ios/Voiid/Voiid/Main/CallLogView.swift:103-153`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/main/ChatsHomeView.kt:210-549,943-1050`; `apps/android/app/src/main/java/com/voiid/app/main/NewChatScreen.kt:59-167`; `apps/android/app/src/main/java/com/voiid/app/main/NewGroupScreen.kt:67-220`; `apps/android/app/src/main/java/com/voiid/app/main/CallLogScreen.kt:79-358`

- **Partial:** `ChatStore.loadError` is populated in `apps/android/app/src/main/java/com/voiid/app/model/Stores.kt:260-262,392-409`, but Android Chats Home never renders it; iOS shows a retry banner (`apps/ios/Voiid/Voiid/Main/ChatsHomeView.swift:57-75`). Add a non-destructive error banner above cached content and a full retry state when cache is empty.
- **Missing:** Android New Chat and New Group have no search state or field; iOS filters names/numbers through `.searchable` (`apps/android/app/src/main/java/com/voiid/app/main/NewChatScreen.kt:59-167`, `apps/android/app/src/main/java/com/voiid/app/main/NewGroupScreen.kt:67-200` vs `apps/ios/Voiid/Voiid/Main/NewChatView.swift:58-94`, `apps/ios/Voiid/Voiid/Main/NewGroupView.swift:24-35,93-107`). Add a custom `VoiidSearchField` and filtered lists.
- **Partial:** Android Message Requests turns an initial fetch failure into an empty list (`apps/android/app/src/main/java/com/voiid/app/main/ReachabilityScreens.kt:273-276`); iOS does the same (`apps/ios/Voiid/Voiid/Main/MessageRequestsView.swift:141-145`). Fix both, but do not label “No requests” after a network failure.
- **Partial:** Android call history is a flat list; iOS groups by day with section labels (`apps/android/app/src/main/java/com/voiid/app/main/CallLogScreen.kt:185-208` vs `apps/ios/Voiid/Voiid/Main/CallLogView.swift:115-153`). Port day grouping and preserve the 76dp inset divider.
- **UI mismatch:** Android Settings, Requests, Find, New Chat, New Group, and Call Log are raw full-screen `Dialog`s; iOS presents them as sheets and keeps settings routes in one `NavigationStack` (`apps/android/app/src/main/java/com/voiid/app/main/ChatsHomeView.kt:369-549` vs `apps/ios/Voiid/Voiid/Main/ChatsHomeView.swift:214-314`). Replace dialog chaining with a custom sheet navigator so Back returns to Settings, not Chats.
- **UI mismatch:** iOS chat header actions use material/glass treatment; Android explicitly uses opaque/tinted circles (`apps/ios/Voiid/Voiid/Main/ChatsHomeView.swift:365-450` vs `apps/android/app/src/main/java/com/voiid/app/main/ChatsHomeView.kt:943-1050`). Centralize the glass/solid fallback in `VoiidTopBar`.

### Chat detail and message rendering

**iOS:** `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:154-232,329-365,781-851,1035-1312,1701-1713,1920-1931`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/main/ChatDetailView.kt:103-730`; `apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt:107-530`; `apps/android/app/src/main/java/com/voiid/app/main/MediaViews.kt:115-145`

- **Broken:** Android colors own messages with `bubbleReceived` and received messages with `surfaceCard`; the `bubbleSent` token is never used (`apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt:230-250`; token at `apps/android/app/src/main/java/com/voiid/app/ui/theme/Color.kt:169-180`). Use `bubbleSent` for own messages and the received surface for peers.
- **Broken:** Android message text and metadata always use `textPrimary`/`textSecondary`; iOS switches to bubble-aware white/secondary-on-sent colors (`apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt:359-370,509-530` vs `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:1261-1312`). Fix text, timestamp, status, quote fill, links, and reactions as one sent-bubble component change.
- **UI mismatch:** Android bubble padding is 10×6dp; iOS is 12×8pt. Radius already matches 16 (`apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt:230-250,107-113` vs `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:1153-1167,1623-1632`).
- **Missing:** iOS taps image media into a full-screen viewer; Android `apps/android/app/src/main/java/com/voiid/app/main/MediaViews.kt:115-145` exposes no tap callback and no image viewer exists. Add a cached full-screen media viewer with zoom, dismiss, loading, and failure states.
- **UI mismatch:** Android clips the entire composer row into one large pill; iOS gives the text field its own pill and keeps attachment/GIF controls separate (`apps/android/app/src/main/java/com/voiid/app/main/ChatDetailView.kt:460-474` vs `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:781-851`). Split the controls and preserve `imePadding`.
- **UI mismatch:** Android header uses a 36dp placeholder avatar, 17sp title, and 11sp presence on an opaque surface; iOS uses a 34pt photo, 17pt title, 12pt presence in native toolbar chrome (`apps/android/app/src/main/java/com/voiid/app/main/ChatDetailView.kt:282-323` vs `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:329-365`).
- **Partial:** Android Message Info formats with `bubbleTime`, which is time-only; iOS renders date + time for non-today messages (`apps/android/app/src/main/java/com/voiid/app/main/ChatSheets.kt:154-205`, `apps/android/app/src/main/java/com/voiid/app/main/DateFormatting.kt:15` vs `apps/ios/Voiid/Voiid/Main/MessageInfoSheet.swift:76-80`).

### Calls

**iOS:** `apps/ios/Voiid/Voiid/Main/CallScreens.swift:64-105,740-867`; `apps/ios/Voiid/Voiid/Main/GroupCallRosterSheet.swift:27-110`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt:113-150,952-1064`; `apps/android/app/src/main/java/com/voiid/app/main/GroupCallRosterSheet.kt:57-130`

- **UI mismatch:** iOS call-type sheet is a fixed 240pt detent with a manual 40×4 handle; Android uses a Material sheet with no fixed detent (`apps/ios/Voiid/Voiid/Main/CallScreens.swift:64-103` vs `apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt:117-150`).
- **UI mismatch:** Android call cards use `softClickable` and also fire `haptics.tap()` in callbacks, producing double feedback; iOS relies on one press-style haptic (`apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt:132-133` vs `apps/ios/Voiid/Voiid/Main/CallScreens.swift:89-103`).
- **Partial:** Android self-preview animates `dx/dy` during the drag, causing the video to lag the finger, and lands by nearest corner without predicted-end velocity; iOS follows 1:1 and uses predicted end/velocity (`apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt:974-1031` vs `apps/ios/Voiid/Voiid/Main/CallScreens.swift:787-851`). Use direct drag translation, velocity projection, drag cancel, and the iOS-equivalent 0.32/0.8 settling spring.
- **UI mismatch:** Android self-preview omits the iOS shadow; size 104×140 and radius 18 already match (`apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt:952-1064` vs `apps/ios/Voiid/Voiid/Main/CallScreens.swift:765-867`).

### Contact profile, safety number, and groups

**iOS:** `apps/ios/Voiid/Voiid/Main/ContactProfileView.swift:18-867`; `apps/ios/Voiid/Voiid/Main/SafetyNumberView.swift:34-300`; `apps/ios/Voiid/Voiid/Main/GroupInfoView.swift:12-293`; `apps/ios/Voiid/Voiid/DesignSystem/Components.swift:25-70`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/main/ContactProfileView.kt:98-996`; `apps/android/app/src/main/java/com/voiid/app/main/SafetyNumberScreen.kt:75-300`; `apps/android/app/src/main/java/com/voiid/app/main/GroupInfoView.kt:68-324`; `apps/android/app/src/main/java/com/voiid/app/ui/components/Components.kt:316-349`

- **Broken:** `ChatService.fetchMembers` returns roles, but Group Info drops `it.role` while constructing every `VMember`, whose default is `MEMBER` (`apps/android/app/src/main/java/com/voiid/app/net/ChatService.kt:172-186`, `apps/android/app/src/main/java/com/voiid/app/main/GroupInfoView.kt:80-86`, `apps/android/app/src/main/java/com/voiid/app/model/GroupModels.kt:21-29`). Pass `role = it.role`, preserve photo/status, and sort You → owner → admins → members as iOS does (`apps/ios/Voiid/Voiid/Main/GroupInfoView.swift:246-270`).
- **Partial:** Because roles are dropped, owner transfer is never offered and every target looks promotable; the Material dialog also exposes destructive remove as the dismiss button (`apps/android/app/src/main/java/com/voiid/app/main/GroupInfoView.kt:170-216`). Gate actions by the caller role and surface server failures instead of optimistic removal.
- **Missing:** Android safety number intentionally omits QR; iOS provides a tap-to-swap QR/digits card with high correction and crisp scaling (`apps/android/app/src/main/java/com/voiid/app/main/SafetyNumberScreen.kt:161-176` vs `apps/ios/Voiid/Voiid/Main/SafetyNumberView.swift:168-224`). Add a vetted QR encoder and scan/compare flow.
- **Partial:** Android `ProfilePhotoViewer` never accepts or renders an image and supports only double-tap; iOS conditionally renders an image and supports pinch plus double-tap (`apps/android/app/src/main/java/com/voiid/app/ui/components/Components.kt:316-349` vs `apps/ios/Voiid/Voiid/DesignSystem/Components.swift:25-70`). Accept the resolved remote/local photo, add pinch/pan with bounds, and preserve 2.5× double-tap.
- **UI mismatch:** Group Info “Invite via link”, “Exit group”, and “Report group” are no-op/back-only (`apps/android/app/src/main/java/com/voiid/app/main/GroupInfoView.kt:152-165`). iOS also leaves invite/report unwired (`apps/ios/Voiid/Voiid/Main/GroupInfoView.swift:163-165,207-210`), so do not prioritize them as Android-only parity gaps; remove misleading affordances or wire both platforms.

### Settings, privacy, storage, and backup

**iOS:** `apps/ios/Voiid/Voiid/Main/Settings/SettingsSheet.swift:172-760`; `apps/ios/Voiid/Voiid/Main/Settings/EditProfileView.swift:46-406`; `apps/ios/Voiid/Voiid/Main/Settings/PrivacySettingsView.swift:45-420`; `apps/ios/Voiid/Voiid/Main/Settings/StorageSettingsView.swift:35-220`; `apps/ios/Voiid/Voiid/Main/Settings/BackupRecoveryView.swift:15-440`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/main/SettingsScreen.kt:95-680`; `apps/android/app/src/main/java/com/voiid/app/main/PrivacySettingsScreen.kt:64-455`; `apps/android/app/src/main/java/com/voiid/app/main/StorageSettingsScreen.kt:51-192`; `apps/android/app/src/main/java/com/voiid/app/main/BackupRecoveryScreen.kt:70-620`

- **Missing:** Android has no account-erasure UI/API route; iOS has danger copy, confirmation, request state, and failure alerts (`apps/ios/Voiid/Voiid/Main/Settings/EditProfileView.swift:213-237,351-406`). `apps/android/app/src/main/java/com/voiid/app/main/LegalScreen.kt:187,229-230` currently tells users deletion is in Edit Profile when it is not. Implement it or correct the legal copy immediately.
- **Partial:** Android closes Settings before opening Backup/Privacy/Storage/Devices/About/Legal (`apps/android/app/src/main/java/com/voiid/app/main/SettingsScreen.kt:471-512`), so Back exits to Chats; iOS pushes those routes inside one NavigationStack (`apps/ios/Voiid/Voiid/Main/Settings/SettingsSheet.swift:244-325`). Keep a single custom settings navigation stack.
- **Missing:** Android logs out immediately; iOS confirms and warns about backup implications (`apps/android/app/src/main/java/com/voiid/app/main/SettingsScreen.kt:514-521` vs `apps/ios/Voiid/Voiid/Main/Settings/SettingsSheet.swift:333-350`). Add `VoiidDialog` confirmation and disabled/busy state.
- **Partial:** Privacy omits the iOS Moments view-receipts section and moves a story toggle onto Settings root (`apps/ios/Voiid/Voiid/Main/Settings/PrivacySettingsView.swift:202-220` vs `apps/android/app/src/main/java/com/voiid/app/main/SettingsScreen.kt:642-660`). Put it under Privacy.
- **UI mismatch:** Android visibility controls are custom three-way segments; iOS uses compact menu pickers (`apps/android/app/src/main/java/com/voiid/app/main/PrivacySettingsScreen.kt:424-455` vs `apps/ios/Voiid/Voiid/Main/Settings/PrivacySettingsView.swift:127-153`). Build one `VoiidPicker` matching iOS row density and selected-value hierarchy.
- **Partial:** Android Linked Devices, Storage, and Blocked Contacts have no pull-to-refresh even where footer copy says to pull; iOS wires `.refreshable` (`apps/ios/Voiid/Voiid/Main/Settings/LinkedDevicesView.swift:99-100`, `apps/ios/Voiid/Voiid/Main/Settings/StorageSettingsView.swift:81-84`, `apps/ios/Voiid/Voiid/Main/Settings/BlockedContactsView.swift:73-75`).
- **Partial:** Storage omits backup date and the “Backup & Recovery” route, and clearing cache has no success haptic (`apps/android/app/src/main/java/com/voiid/app/main/StorageSettingsScreen.kt:111-161` vs `apps/ios/Voiid/Voiid/Main/Settings/StorageSettingsView.swift:136-191,210-218`).
- **Partial:** Backup metadata/network failures are converted to “no backup” with `getOrNull`, and Backup Now uses silent `runCatching` (`apps/android/app/src/main/java/com/voiid/app/main/BackupRecoveryScreen.kt:91-96,150-152`). Preserve the last good state, show actionable error, and fire error/success haptics and a toast like iOS (`apps/ios/Voiid/Voiid/Main/Settings/BackupRecoveryView.swift:86-118,203-259,285-304`).

### Communities

**iOS:** `apps/ios/Voiid/Voiid/Main/CommunitiesHomeView.swift:24-371`; `apps/ios/Voiid/Voiid/Main/CommunityCreateFlow.swift:140-689`; `apps/ios/Voiid/Voiid/Main/CommunityDetailView.swift:15-423`; `apps/ios/Voiid/Voiid/Main/CommunityHomeTab.swift:20-335`; `apps/ios/Voiid/Voiid/Main/CommunityTabs.swift:37-816`; `apps/ios/Voiid/Voiid/Main/CommunityInboxView.swift:30-307`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt:46-266`

- **Missing:** Android's Create button only fires haptics; there is no create screen or API flow (`apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt:91-95`). Port all five iOS steps: identity, privacy, spaces, rules, invite (`apps/ios/Voiid/Voiid/Main/CommunityCreateFlow.swift:140-172,220-604`).
- **Missing:** Android detail has only header/join, tournaments, and events; iOS has Home, Spaces, Events, Members, About, host bar, invite, actions, and host inbox (`apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt:186-266` vs `apps/ios/Voiid/Voiid/Main/CommunityDetailView.swift:208-262,327-423`).
- **Missing:** Host inbox and thread states are absent (`apps/ios/Voiid/Voiid/Main/CommunityInboxView.swift:30-307`).
- **Partial:** Android home has no pull-to-refresh; iOS refreshes membership and keeps error distinct from empty (`apps/ios/Voiid/Voiid/Main/CommunitiesHomeView.swift:70-95`).
- **UI mismatch:** Android community cards use a generic 52dp Groups icon; iOS uses a 46pt avatar plus host/joined/requested/suspended/policy treatments (`apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt:135-167` vs `apps/ios/Voiid/Voiid/Main/CommunitiesHomeView.swift:180-275`). Port card semantics before fine visual tuning.

### Moments

**iOS:** `apps/ios/Voiid/Voiid/Main/Stories/StoriesHomeView.swift:16-190`; `apps/ios/Voiid/Voiid/Main/Stories/StoryCameraView.swift:33-160`; `apps/ios/Voiid/Voiid/Main/Stories/StoryComposerView.swift:20-214`; `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift:22-390`; `apps/ios/Voiid/Voiid/Main/Stories/StoryViewersSheet.swift:13-76`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/main/stories/StoriesHomeView.kt:50-172`; `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryCameraView.kt:49-123`; `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryComposerSheet.kt:76-270`; `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewerView.kt:82-381`; `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewersSheet.kt:37-90`

- **Missing:** Android camera is explicitly photo-only; iOS tap-captures photo and hold-records video up to 30 seconds (`apps/android/app/src/main/java/com/voiid/app/main/stories/StoryCameraView.kt:40-123` vs `apps/ios/Voiid/Voiid/Main/Stories/StoryCameraView.swift:20-118`). Add press-and-hold video, recording timer, stop/cancel, and permission recovery.
- **Partial:** Android capture failure only writes Logcat and the denied-permission state is a black preview (`apps/android/app/src/main/java/com/voiid/app/main/stories/StoryCameraView.kt:49-123`); iOS shows a user-facing alert (`apps/ios/Voiid/Voiid/Main/Stories/StoryCameraView.swift:80-100`).
- **Missing:** Android home has no pull-to-refresh or own-story delete menu (`apps/android/app/src/main/java/com/voiid/app/main/stories/StoriesHomeView.kt:49-172` vs `apps/ios/Voiid/Voiid/Main/Stories/StoriesHomeView.swift:50-101`).
- **Partial:** Android image preparation does not recheck the 10MB limit after encoding, and video is never transcoded; iOS verifies encoded size and exports H.264 720p before upload (`apps/android/app/src/main/java/com/voiid/app/main/stories/StoryComposerSheet.kt:230-256` vs `apps/ios/Voiid/Voiid/Main/Stories/StoryComposerView.swift:175-212`).
- **UI mismatch:** iOS reply opens a fixed 260pt sheet; Android renders the input inline at the viewer bottom (`apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift:367-384` vs `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewerView.kt:352-381`). Use `VoiidSheet(.fixed(260))`, IME avoidance, sent toast, and dismiss-after-success.
- **Partial:** Android viewer-list rows receive `photoUrl = null`; iOS renders real viewer photos (`apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewersSheet.kt:80-85` vs `apps/ios/Voiid/Voiid/Main/Stories/StoryViewersSheet.swift:31-39`).

### Map and live location

**iOS:** `apps/ios/Voiid/Voiid/Main/MapTabView.swift:121-173`; `apps/ios/Voiid/Voiid/Main/MapAudienceSheet.swift:20-286`; `apps/ios/Voiid/Voiid/Main/LocationBanner.swift:17-95`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/main/MapTabView.kt:199-264`; `apps/android/app/src/main/java/com/voiid/app/main/MapAudienceSheet.kt:71-335`; `apps/android/app/src/main/java/com/voiid/app/main/LocationBanner.kt:35-65`

- **Missing:** iOS manage-audience sheet has “Add People”; Android omits it, and the visible-status pill only reopens MANAGE mode (`apps/ios/Voiid/Voiid/Main/MapAudienceSheet.swift:251-261` vs `apps/android/app/src/main/java/com/voiid/app/main/MapAudienceSheet.kt:331-335`; `apps/android/app/src/main/java/com/voiid/app/main/MapTabView.kt:251-263`). Add a MANAGE → CHOOSE transition and persist newly selected users.
- **Missing:** iOS Ghost Mode offers one hour, until tomorrow, or until turned off; Android toggles ghost immediately with no duration (`apps/ios/Voiid/Voiid/Main/MapTabView.swift:160-167` vs `apps/android/app/src/main/java/com/voiid/app/main/MapTabView.kt:217-233`). Port the chooser and expiry display.
- **Missing:** Android “Stop all” live shares executes immediately; iOS requires confirmation (`apps/android/app/src/main/java/com/voiid/app/main/LocationBanner.kt:57-62` vs `apps/ios/Voiid/Voiid/Main/LocationBanner.swift:46-74`). Add rigid haptic, custom destructive dialog, busy state, and result feedback.
- **UI mismatch:** iOS Map uses native title/toolbar with one eye action; Android uses a custom 24sp title plus labeled toggle (`apps/ios/Voiid/Voiid/Main/MapTabView.swift:121-135` vs `apps/android/app/src/main/java/com/voiid/app/main/MapTabView.kt:215-264`). Match the iOS compact header and keep ghost detail in the sheet/dialog.
- **UI mismatch:** Android live banner collapses title and time into one line, has no animated entrance, no error-red Stop pill, and no haptic (`apps/android/app/src/main/java/com/voiid/app/main/LocationBanner.kt:45-63` vs `apps/ios/Voiid/Voiid/Main/LocationBanner.swift:31-74`).

### Clips

**iOS:** `apps/ios/Voiid/Voiid/Main/Clips/ClipsFeedView.swift:14-363`; `apps/ios/Voiid/Voiid/Main/Clips/ClipCameraView.swift:66-330`; `apps/ios/Voiid/Voiid/Main/Clips/CreatorProfileView.swift:21-120`; `apps/ios/Voiid/Voiid/Main/Clips/MyClipsView.swift:17-120`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/main/clips/ClipsFeedView.kt:66-225`; `apps/android/app/src/main/java/com/voiid/app/main/clips/ClipComposerFlow.kt:78-167`; `apps/android/app/src/main/java/com/voiid/app/main/clips/CreatorProfileView.kt:88-177`; `apps/android/app/src/main/java/com/voiid/app/main/clips/MyClipsView.kt:81-140`

- **Missing:** Android Explore, Following, Creator, and My Clips expose no pull-to-refresh; iOS wires refresh in all four (`apps/ios/Voiid/Voiid/Main/Clips/ClipsFeedView.swift:211-268,304-364`, `apps/ios/Voiid/Voiid/Main/Clips/CreatorProfileView.swift:96-108`, `apps/ios/Voiid/Voiid/Main/Clips/MyClipsView.swift:68-92`).
- **Partial:** Android library import immediately accepts the picked URI; iOS asks before replacing/discarding existing camera takes (`apps/android/app/src/main/java/com/voiid/app/main/clips/ClipComposerFlow.kt:136-167` vs `apps/ios/Voiid/Voiid/Main/Clips/ClipCameraView.swift:142-165`). Add a destructive `VoiidDialog` naming the number of takes affected.
- **UI mismatch:** Handle, creator edit, my-clip edit, and delete use Material sheets/dialog (`apps/android/app/src/main/java/com/voiid/app/main/clips/CreatorHandleSheet.kt:78-110`, `apps/android/app/src/main/java/com/voiid/app/main/clips/CreatorProfileView.kt:498-518`, `apps/android/app/src/main/java/com/voiid/app/main/clips/MyClipsView.kt:159-190,270-310`). Migrate together to shared custom primitives.

### Games

**iOS:** `apps/ios/Voiid/Voiid/Games/GamesHomeView.swift:303-410`; `apps/ios/Voiid/Voiid/Games/GameSetupSheet.swift:153-168`; `apps/ios/Voiid/Voiid/Games/OversSheet.swift:20-59`; `apps/ios/Voiid/Voiid/Games/DuelSheet.swift:28-94`; `apps/ios/Voiid/Voiid/Games/GameSettingsSheet.swift:25-140`  →  **Android:** matching files under `apps/android/app/src/main/java/com/voiid/app/main/games/`

- **UI mismatch:** iOS settings is medium; skin picker is medium/large; Game Setup has computed-height + large with visible handle; Overs is fixed 240pt; Duel is fixed 360pt (`apps/ios/Voiid/Voiid/Games/GamesHomeView.swift:303-309`, `apps/ios/Voiid/Voiid/Games/GameSetupSheet.swift:153-168`, `apps/ios/Voiid/Voiid/Games/OversSheet.swift:54-59`, `apps/ios/Voiid/Voiid/Games/DuelSheet.swift:89-94`). Android uses Material sheets and does not encode those detents (`apps/android/app/src/main/java/com/voiid/app/main/games/GameSettingsSheet.kt:63-81`, `apps/android/app/src/main/java/com/voiid/app/main/games/GameSetupSheet.kt:98-105`, `apps/android/app/src/main/java/com/voiid/app/main/games/OversSheet.kt:42-60`, `apps/android/app/src/main/java/com/voiid/app/main/games/DuelSheet.kt:48-71`).
- **UI mismatch:** Game Settings still uses stock Material `Switch` (`apps/android/app/src/main/java/com/voiid/app/main/games/GameSettingsSheet.kt:239`). Replace it with existing custom `VoiidToggle` (`apps/android/app/src/main/java/com/voiid/app/ui/components/Components.kt:221-254`).
- **Partial:** Preserve the existing reduced-motion work in Ludo, Tic-tac-toe, Sea Battle, Snake, and Match End; route new custom sheet transitions through the same setting (`apps/android/app/src/main/java/com/voiid/app/main/games/ReduceMotion.kt`, `apps/android/app/src/main/java/com/voiid/app/ui/components/ReduceMotion.kt:27-33`).

### AI

**iOS:** `apps/ios/Voiid/Voiid/Main/AIChatView.swift:12-86`  →  **Android:** `apps/android/app/src/main/java/com/voiid/app/main/AIChatView.kt:52-154`

- **UI mismatch:** iOS header and input use `.ultraThinMaterial`; Android uses opaque background surfaces (`apps/ios/Voiid/Voiid/Main/AIChatView.swift:40-48,83-86` vs `apps/android/app/src/main/java/com/voiid/app/main/AIChatView.kt:62-76,89-136`). Use the same translucent custom chrome as Chats.
- **UI mismatch:** iOS inserts bubbles with scale + opacity; Android bubble creation has no insertion transition (`apps/ios/Voiid/Voiid/Main/AIChatView.swift:50-60` vs `apps/android/app/src/main/java/com/voiid/app/main/AIChatView.kt:139-154`). Add a short non-vestibular opacity/0.98→1 transition.

### Sheets and overlays

No Android sheet is a custom Voiid primitive. The table is the complete iOS overlay inventory from executable `.sheet`, `.fullScreenCover`, `.alert`, and `.confirmationDialog` sites; multiple overlays in one source file are enumerated in one row.

| iOS source / overlays | Android equivalent and concrete delta |
|---|---|
| `apps/ios/Voiid/Voiid/Networking/ConfigService.swift:59-61` — required update full-screen | Inline `UpdateRequiredScreen` (`apps/android/app/src/main/java/com/voiid/app/MainActivity.kt:331-340`); acceptable full-screen equivalence. |
| `apps/ios/Voiid/Voiid/Legal/ConsentPromptView.swift:103-110` — legal document sheet; consent failure alert | Raw full-width `Dialog` for the entire prompt (`apps/android/app/src/main/java/com/voiid/app/MainActivity.kt:306-315`); document swaps inline; no custom sheet/dialog. |
| `apps/ios/Voiid/Voiid/Main/NewGroupView.swift:50-54` — capacity alert | Material `AlertDialog` (`apps/android/app/src/main/java/com/voiid/app/main/NewGroupScreen.kt:203-219`). |
| `apps/ios/Voiid/Voiid/Main/ChatsHomeView.swift:214-314` — Call Log, Settings, Find, Requests, New Chat, New Group, Call Type sheets; delete alert; active-call cover | Twelve raw full-screen dialogs plus Material delete alert (`apps/android/app/src/main/java/com/voiid/app/main/ChatsHomeView.kt:369-549`); sheet hierarchy/dismissal semantics lost. |
| `apps/ios/Voiid/Voiid/Main/GroupInfoView.swift:46-58` — photo cover, shared media, action-error alert, member action dialog | Inline full-screen photo, Material shared-media sheet, Material member dialog; no action-error state (`apps/android/app/src/main/java/com/voiid/app/main/GroupInfoView.kt:170-237`). |
| `apps/ios/Voiid/Voiid/Main/Settings/LinkedDevicesView.swift:100-120` — unlink confirmation | Material `AlertDialog` (`apps/android/app/src/main/java/com/voiid/app/main/LinkedDevicesScreen.kt:178-200`). |
| `apps/ios/Voiid/Voiid/Main/Settings/EditProfileView.swift:213-304` — delete, erasure success/failure, discard, photo-source, camera cover | **MISSING** with the dedicated Edit Profile route. |
| `apps/ios/Voiid/Voiid/Main/Settings/SettingsSheet.swift:333-350` — logout confirmation | **MISSING**; Android logs out directly (`apps/android/app/src/main/java/com/voiid/app/main/SettingsScreen.kt:514-521`). |
| `apps/ios/Voiid/Voiid/Main/Settings/BlockedContactsView.swift:76-96` — unblock confirmation/failure | Two Material `AlertDialog`s (`apps/android/app/src/main/java/com/voiid/app/main/BlockedContactsScreen.kt:131-181`). |
| `apps/ios/Voiid/Voiid/Main/Settings/LegalView.swift:51-70` — consent withdrawal/failure | Material `AlertDialog` (`apps/android/app/src/main/java/com/voiid/app/main/LegalScreen.kt:222-240`) plus inline error handling. |
| `apps/ios/Voiid/Voiid/Main/Settings/PrivacySettingsView.swift:314-322` — rotate-PIN confirmation | Material `AlertDialog` (`apps/android/app/src/main/java/com/voiid/app/main/PrivacySettingsScreen.kt:110-132`). |
| `apps/ios/Voiid/Voiid/Main/Settings/BackupRecoveryView.swift:89-93` — setup, phrase, change-PIN sheets | Full-screen internal branch swaps (`apps/android/app/src/main/java/com/voiid/app/main/BackupRecoveryScreen.kt:130-169,303-620`); no drag/detent/returning sheet stack. |
| `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:154-232,1218` — safety, GIF, poll, location, info, forward, bulk-forward, emoji sheets; delete/bulk alerts; image/call covers | GIF/emoji/forward/info/poll/location use Material sheets; deletes use Material alerts; safety/call are inline covers; image viewer missing (`apps/android/app/src/main/java/com/voiid/app/main/ChatDetailView.kt:110-255,674-715`; `apps/android/app/src/main/java/com/voiid/app/main/ChatSheets.kt:108-249`). |
| `apps/ios/Voiid/Voiid/Main/Clips/MyClipsView.swift:34-49` — edit sheet/delete confirmation | Material edit sheet + Material alert (`apps/android/app/src/main/java/com/voiid/app/main/clips/MyClipsView.kt:159-190,270-310`). |
| `apps/ios/Voiid/Voiid/Main/Clips/CreatorProfileView.swift:52-65` — edit sheet/clip cover | Material edit sheet + inline full-screen player (`apps/android/app/src/main/java/com/voiid/app/main/clips/CreatorProfileView.kt:88-177,498-518`). |
| `apps/ios/Voiid/Voiid/Main/Clips/ClipsFeedView.swift:61-87` — Explore/Following clip covers, composer cover, handle sheet | Inline root overlays + Material handle sheet (`apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:367-700`; `apps/android/app/src/main/java/com/voiid/app/main/clips/CreatorHandleSheet.kt:78-110`). |
| `apps/ios/Voiid/Voiid/Main/Clips/ClipCameraView.swift:153-165` — replace-takes confirmation | **MISSING**; Android accepts the library URI immediately (`apps/android/app/src/main/java/com/voiid/app/main/clips/ClipComposerFlow.kt:136-167`). |
| `apps/ios/Voiid/Voiid/Main/CommunityDetailView.swift:89` — host inbox sheet | **MISSING**. |
| `apps/ios/Voiid/Voiid/Main/CallScreens.swift:332` — add-person sheet | Raw Compose `Dialog` (`apps/android/app/src/main/java/com/voiid/app/main/CallScreens.kt:562`). |
| `apps/ios/Voiid/Voiid/Main/MapTabView.swift:143-173` — explainer cover, audience picker/list sheets, Ghost confirmation, error alert | Explainer inline; one Material audience sheet; Ghost confirmation missing; error inline (`apps/android/app/src/main/java/com/voiid/app/main/MapTabView.kt:199-264`; `apps/android/app/src/main/java/com/voiid/app/main/MapAudienceSheet.kt:83-124`). |
| `apps/ios/Voiid/Voiid/Main/Stories/StoryCameraView.swift:80-100` — capture/permission alert | **MISSING**; Android logs capture failure (`apps/android/app/src/main/java/com/voiid/app/main/stories/StoryCameraView.kt:49-123`). |
| `apps/ios/Voiid/Voiid/Main/Stories/StoryComposerView.swift:68-72` — camera cover, audience sheet | Inline composer/camera branch + Material audience sheet (`apps/android/app/src/main/java/com/voiid/app/main/stories/StoryComposerSheet.kt:76-270`; `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryAudiencePicker.kt:57-64`). |
| `apps/ios/Voiid/Voiid/Main/Stories/StoriesHomeView.swift:52-59` — composer sheet, context/mine viewer covers | Root inline overlays (`apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:559-700`). |
| `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift:206-207,367-384` — viewers and fixed reply sheets | Material viewers sheet; reply is inline (`apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewersSheet.kt:43-90`; `apps/android/app/src/main/java/com/voiid/app/main/stories/StoryViewerView.kt:352-381`). |
| `apps/ios/Voiid/Voiid/Main/CallLogView.swift:82-94` — clear confirmation | Material `AlertDialog` (`apps/android/app/src/main/java/com/voiid/app/main/CallLogScreen.kt:94-121`). |
| `apps/ios/Voiid/Voiid/Main/CommunitiesHomeView.swift:57-66` — create sheet | **MISSING**. |
| `apps/ios/Voiid/Voiid/Main/NewChatView.swift:52-54` — OS share sheet | Android OS Sharesheet via `Intent.createChooser` (`apps/android/app/src/main/java/com/voiid/app/main/NewChatScreen.kt:145-154`); platform-appropriate equivalent. |
| `apps/ios/Voiid/Voiid/Main/GroupCallScreen.swift:74-77` — roster sheet | Material sheet (`apps/android/app/src/main/java/com/voiid/app/main/GroupCallRosterSheet.kt:57-83`), no medium/large parity. |
| `apps/ios/Voiid/Voiid/Main/LocationPinBubble.swift:97-100` — location detail cover | Raw Compose `Dialog` (`apps/android/app/src/main/java/com/voiid/app/main/LocationViews.kt:202`). |
| `apps/ios/Voiid/Voiid/Main/ContactProfileView.swift:142-220` — photo cover, safety/media/report sheets, clear/block/report confirmations, block/not-available alerts | Inline covers, Material media sheet, raw report dialog, and Material alerts (`apps/android/app/src/main/java/com/voiid/app/main/ContactProfileView.kt:190-331,718-731`). |
| `apps/ios/Voiid/Voiid/Main/LocationBanner.swift:70-73` — stop-all confirmation | **MISSING**; Android stops immediately (`apps/android/app/src/main/java/com/voiid/app/main/LocationBanner.kt:57-62`). |
| `apps/ios/Voiid/Voiid/Games/SeaBattleView.swift:103-110` — resign alert | Material `AlertDialog` (`apps/android/app/src/main/java/com/voiid/app/main/games/SeaBattleScreen.kt:155`). |
| `apps/ios/Voiid/Voiid/Games/GamesHomeView.swift:303-410` — settings, skin, setup, opponent/overs/duel chain | Material sheets in matching Android game files; explicit iOS detents not represented. |
| `apps/ios/Voiid/Voiid/Games/MatchEndOverlay.swift:92-96` and `apps/ios/Voiid/Voiid/Games/SnakeArenaView.swift:151-158` — OS share sheets | Android OS Sharesheet from `apps/android/app/src/main/java/com/voiid/app/main/games/MatchEndOverlay.kt:220-225`; platform-appropriate equivalent. |
| `apps/ios/Voiid/Voiid/ContentView.swift:61-89` — consent sheet, incoming-call cover, community-invite sheet | Raw full-width consent dialog, root call overlay, Material community sheet (`apps/android/app/src/main/java/com/voiid/app/MainActivity.kt:306-327`). |
| `apps/ios/Voiid/Voiid/Onboarding/WelcomeTermsScreen.swift:106-108` — legal document sheet | Inline Android document route (`apps/android/app/src/main/java/com/voiid/app/onboarding/WelcomeTermsScreen.kt:79-88`). |
| `apps/ios/Voiid/Voiid/Onboarding/OTPScreen.swift:141-145` — restore cover | Inline Android restore branch; functionality is partial (`apps/android/app/src/main/java/com/voiid/app/onboarding/RestoreFlow.kt:45-232`). |
| `apps/ios/Voiid/Voiid/Onboarding/PhoneScreen.swift:156-164` — country sheet | Material sheet with `skipPartiallyExpanded = true`, no drag handle, 92% height (`apps/android/app/src/main/java/com/voiid/app/onboarding/CountryPickerSheet.kt:64-86`). |

#### Sheet mechanics delta

- **Detents:** iOS explicitly uses medium+large for GIF, poll, location, and group roster; medium for message info/settings; large for shared media; 240pt for call type/Overs; 260pt for story reply; 360pt for Duel; computed height+large for Game Setup (`apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:154-184`; `apps/ios/Voiid/Voiid/Main/SharedMediaSheet.swift:67`; `apps/ios/Voiid/Voiid/Main/GroupCallRosterSheet.swift:66`; `apps/ios/Voiid/Voiid/Main/CallScreens.swift:86`; `apps/ios/Voiid/Voiid/Main/Stories/StoryViewerView.swift:383`; `apps/ios/Voiid/Voiid/Games/OversSheet.swift:58`; `apps/ios/Voiid/Voiid/Games/DuelSheet.swift:93`; `apps/ios/Voiid/Voiid/Games/GameSetupSheet.swift:153-168`). Most Android sheets force `skipPartiallyExpanded = true`; they cannot stop at the iOS medium detent.
- **Drag handle:** Android explicitly removes the handle from country, emoji, forward, message info, poll, and shared media (`apps/android/app/src/main/java/com/voiid/app/onboarding/CountryPickerSheet.kt:80-84`; `apps/android/app/src/main/java/com/voiid/app/main/EmojiPickerSheet.kt:48-51`; `apps/android/app/src/main/java/com/voiid/app/main/ChatSheets.kt:110-218`; `apps/android/app/src/main/java/com/voiid/app/main/SharedMediaSheet.kt:76-88`). Game Setup must always show one to match iOS (`apps/ios/Voiid/Voiid/Games/GameSetupSheet.swift:166-167`).
- **Radius / scrim / spring:** no iOS source sets `presentationCornerRadius`, scrim opacity, or a sheet spring; SwiftUI system behavior is the reference. No Android `ModalBottomSheet` call sets `shape`, `scrimColor`, or a motion spec, so it inherits Material behavior. Do not invent numeric parity: capture the iOS reference on target devices, then codify measured `VoiidSheet` tokens and screenshot/interaction tests.
- **Drag-to-dismiss:** neither platform disables interactive dismissal in the audited sites. Preserve drag-to-dismiss in `VoiidSheet`, including nested-scroll handoff and velocity-based settle.
- **Insets:** only Community Join, Location, Creator Handle/Edit, Duel, and Game Settings explicitly add navigation-bar padding; only creator handle/edit add `imePadding` (`apps/android/app/src/main/java/com/voiid/app/main/CommunityJoinSheet.kt:96-103`; `apps/android/app/src/main/java/com/voiid/app/main/LocationSheets.kt:134-135`; `apps/android/app/src/main/java/com/voiid/app/main/clips/CreatorHandleSheet.kt:98-110`; `apps/android/app/src/main/java/com/voiid/app/main/clips/CreatorProfileView.kt:506-518`; `apps/android/app/src/main/java/com/voiid/app/main/games/DuelSheet.kt:63-71`; `apps/android/app/src/main/java/com/voiid/app/main/games/GameSettingsSheet.kt:73-81`). Make safe-area, navigation-bar, and keyboard avoidance defaults of the sheet primitive.

## Design system deltas

| Token / behavior | iOS value | Android value | Fix |
|---|---|---|---|
| Spacing | 4, 8, 16, 24, 32, 48pt (`apps/ios/Voiid/Voiid/DesignSystem/Theme.swift:178-185`) | 4, 8, 16, 24, 32, 48dp (`apps/android/app/src/main/java/com/voiid/app/ui/theme/Dimens.kt:5-12`) | Values match; replace one-off 10/14/20/28 paddings only where the paired iOS screen uses tokens. |
| Radius | 8, 12, 16, pill (`apps/ios/Voiid/Voiid/DesignSystem/Theme.swift:189-194`) | 8, 12, 16, pill (`apps/android/app/src/main/java/com/voiid/app/ui/theme/Dimens.kt:14-20`) | Values match; route sheet/dialog/card shapes through tokens. |
| Typeface | SF Pro Rounded; Urbanist logo (`apps/ios/Voiid/Voiid/DesignSystem/Theme.swift:201-220`) | Nunito variable approximation (`apps/android/app/src/main/java/com/voiid/app/ui/theme/Type.kt:13-59`) | Keep the legal Android font; tune explicit line height/tracking per role against iOS screenshots. Current Android styles set size/weight but no line height or tracking. |
| Type scale | 34/22/17/17/16/15/13/12pt (`apps/ios/Voiid/Voiid/DesignSystem/Theme.swift:201-220`) | Same nominal sizes (`apps/android/app/src/main/java/com/voiid/app/ui/theme/Type.kt:43-59`) | Add semantic `display/title/headline/body/callout/subhead/footnote/caption` styles with line height and letter spacing; stop rebuilding `rounded(size)` ad hoc. |
| Primary/background/card | `#13828C`; `#F6F8F8/#080C0E`; `#FFFFFF/#111719` (`apps/ios/Voiid/Voiid/DesignSystem/Theme.swift:61-70`) | Same (`apps/android/app/src/main/java/com/voiid/app/ui/theme/Color.kt:160-165`) | Keep. |
| Surface semantics | `surfaceDeep #EDF1F1/#080C0E`; `surfaceRaised #EDF1F1/#182124` (`apps/ios/Voiid/Voiid/DesignSystem/Theme.swift:68-70`) | Raw palette exists but no composable semantic token (`apps/android/app/src/main/java/com/voiid/app/ui/theme/Color.kt:32-137`) | Add and use semantic tokens for overlay depth instead of `background`/`surfaceCard` everywhere. |
| Accent states | pressed `#0E6E77`; tint `#D9EFF0/#123538`; accent ink (`apps/ios/Voiid/Voiid/DesignSystem/Theme.swift:110-129`) | Missing composable tokens (`apps/android/app/src/main/java/com/voiid/app/ui/theme/Color.kt:32-137`) | Add `primaryPressed`, `accentTint`, `accentInk`; use for pressed/selected states. |
| Success | `#238A58/#2FA36B` (`apps/ios/Voiid/Voiid/DesignSystem/Theme.swift:162`) | `#15803D/#22C55E` (`apps/android/app/src/main/java/com/voiid/app/ui/theme/Color.kt:239-240`) | Change Android palette to iOS values. |
| Error | `#D83A40/#E5484D` (`apps/ios/Voiid/Voiid/DesignSystem/Theme.swift:167`) | `#DC2626/#EF4444` (`apps/android/app/src/main/java/com/voiid/app/ui/theme/Color.kt:241-242`) | Change Android palette to iOS values. |
| Soft press | scale 0.96, opacity 0.9, spring response 0.3/damping 0.6, one soft haptic (`apps/ios/Voiid/Voiid/DesignSystem/Components.swift:85-96`) | scale 0.96, alpha 0.9, damping 0.6 with `StiffnessMediumLow` (`apps/android/app/src/main/java/com/voiid/app/ui/components/Components.kt:62-90`) | Define one `VoiidMotion.softPress` spring calibrated to the 0.3s iOS response; remove callback-level duplicate haptics. |
| Tab press | scale 0.92; response 0.22/damping 0.7 (`apps/ios/Voiid/Voiid/Main/RootTabView.swift:435-444`) | scale 0.92; damping 0.7/MediumLow (`apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:974-985`) | Calibrate shared spring; current behavior is directionally correct. |
| Tab select | content fade 180ms; indicator 0.32/0.9; icon 0.28/0.85 (`apps/ios/Voiid/Voiid/Main/RootTabView.swift:138-143,322-371`) | fade 180ms; split indicator springs 0.82; icon 0.85 (`apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt:291-299,925-995`) | Preserve 180ms; correct active 1.10 phase and tune indicator by visual regression. |
| Haptic map | tap/light, soft, rigid, success, error, selection, boundary (`apps/ios/Voiid/Voiid/DesignSystem/Haptics.swift:10-47`) | tap, soft, rigid, selection, success, boundary; no error (`apps/android/app/src/main/java/com/voiid/app/ui/components/Haptics.kt:28-117`) | Add error; document one haptic per action; align boundary second impact to iOS 70ms (`apps/ios/Voiid/Voiid/DesignSystem/Haptics.swift:37-46`). |
| Reduce motion | Onboarding Verified/Terms, chats, calls, group calls, games gated (`apps/ios/Voiid/Voiid/Onboarding/VerifiedScreen.swift:141-180`; other call sites) | setting helper exists; used mainly chats/calls/games (`apps/android/app/src/main/java/com/voiid/app/ui/components/ReduceMotion.kt:27-33`) | Gate onboarding handoff, sheet travel, large full-screen slides, story/clip travel; keep opacity feedback. |
| Sent bubble | teal `bubbleSent`, white content (`apps/ios/Voiid/Voiid/DesignSystem/Theme.swift:76-82`; `apps/ios/Voiid/Voiid/Main/ChatDetailView.swift:1160-1167,1303-1312`) | token exists but renderer uses received/card surfaces and dark text (`apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt:230-250,359-370`) | Fix renderer and add screenshot tests in both themes. |
| Sheet mechanics | SwiftUI system; explicit detents listed above | Material defaults; most sheets expanded-only | Replace with measured custom `VoiidSheet` spec; do not use Material3 defaults. |

## Custom component backlog

| Component | Required parity contract |
|---|---|
| `VoiidSheet` | Fixed, medium, large, computed+large detents; initial detent; optional 40×4 handle; custom top radii/scrim tokens; direct finger tracking; velocity settle; drag-to-dismiss; nested-scroll transfer; safe/navigation/IME insets; keyboard-aware detent growth; reduced-motion fade fallback; async hide-before-callback. |
| `VoiidDialog` | Branded surface/radius/stroke/scrim; title/body/action hierarchy; destructive and cancel roles; 48dp targets; disabled/busy states; focus trap; Back/scrim dismissal policy; IME avoidance; error/success haptic hooks. Replace all 18 Material alerts. |
| `VoiidModalNavigator` | Sheet-local back stack for Settings, Backup, legal documents, and subflows; preserves parent sheet and returns to the previous route instead of Chats. |
| `VoiidNavBar` | 64dp content height; five visible scrollable slots; 22dp icons; 22×3 indicator; 180ms page fade; 1.10 active phase; ghost/unread badges; 0.92 press; translucent blurred surface with 0.5dp divider and navigation inset. |
| `VoiidTopBar` | Compact inline title, back/close/action slots, status-bar handling, translucent material mode, photo-overlay white mode, 44–48dp hit targets, keyboard-safe focus behavior. |
| `VoiidPicker` / `VoiidSegmentedControl` | Menu-row picker and true two-option segment variants; 52dp settings row; selected-value hierarchy; 3dp internal inset where segmented; selection haptic; disabled state; keyboard/accessibility navigation. Replace scattered hand-built segments and stock game `Switch`. |
| `VoiidSearchField` | 48–50dp height, 12dp radius/pill option, search/clear icons, focused border, submit action, IME Search, debounce hook, empty/error/loading slots. Use in New Chat, New Group, Communities, country/GIF pickers. |
| `VoiidPullRefresh` | Custom indicator/color/motion; works with LazyColumn/grid/scroll; no Material visual; disabled while already loading; success/error completion; reduced-motion path. Adopt on Communities, Moments, Clips, Linked Devices, Storage, Blocked Contacts. |
| `VoiidToast` | Top/bottom safe-area placement; queue; success/error/info styles; 2–3s auto-dismiss; swipe/tap dismissal; screen-reader announcement; keyboard avoidance; reduced-motion opacity. Replace silent backup/story outcomes. |
| `VoiidPhotoViewer` | Real remote/local image; cached loading/error states; pinch + pan + bounded scale; 2.5× double-tap; direct swipe/close; black system-bar treatment; title/actions; reduced motion. Reuse for profile and message media. |
| `VoiidStateView` | Loading, empty, offline, and error/retry must be distinct; optional cached-content banner; icon/title/body/action slots. Prevent network errors from becoming empty states. |
| `VoiidHaptics` map | Add error; one named semantic call per completed intent; remove stacked press+callback taps; boundary sequence; no haptic for disabled controls. |

## Implementation checklist

- [x] P0 — Fix sent-message fill/text/metadata/quote colors and 12×8dp padding in `apps/android/app/src/main/java/com/voiid/app/main/ChatUI.kt`.
    - Implementation: `ChatUI.kt` — `bubbleSent` for own bubbles / `bubbleReceived` + 0.5dp divider hairline for peers, 12×8dp padding, bubble-aware `bubbleText`/`bubbleTextSecondary`/`bubbleAccent` helpers applied to text, mentions, timestamps, status (Seen bold on-bubble, Failed error), forwarded tag, quote rail/fill (`white @0.16` on own), deleted-message ink.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P0 — Implement OTP resend, countdown/expiry, current verification-ID replacement, autofill, and error haptics.
    - Implementation (`OtpScreen.kt`): Resend calls `FirebasePhoneAuth.sendCode`, REPLACES `activeVerificationId`, clears the code, restarts a real 120s wall-clock countdown (mm:ss tick, expiry copy at 0), refocuses, busy/disabled states; verify uses the live id; verification AND resend failures fire the new `VoiidHaptics.error()` (Haptics.kt); Change-number affordance added.
    - Autofill: compose BOM upgraded to `2025.05.01` (ui 1.8.2) and the hidden field now carries `semantics { contentType = ContentType.SmsOtpCode }` — the Android counterpart of iOS `.textContentType(.oneTimeCode)`; credential managers/Gboard offer the SMS code into this field.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.

- [x] P0 — Add Verified screen and route both successful OTP exits through it.
    - Implementation: new `onboarding/VerifiedScreen.kt` — 116dp ring (4dp stroke, lit-edge gradient), 54×40 tick trimmed via `PathMeasure` (7dp stroke), halo, 450/300/500/750/350ms staged sequence with 1.1s hold, success haptic at tick land, reduced-motion instant-present branch; `OnboardingFlow.kt` adds the `VERIFIED` step so both OTP exits (new-user → Signup, returning-user → enter app) route through it; Back disabled on Verified.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.

- [x] P0 — Reinstate explicit terms checkbox, disabled Continue, complete legal-document list, and sheet presentation.
    - Implementation: `WelcomeTermsScreen.kt` rewritten to the iOS contract — explicit 26dp/8dp-radius/2dp-stroke consent checkbox with selection haptic + tick scale-in, Continue gated on acceptance (dimmed, tap-swallowed), six alphabetical document rows (iOS mapping) each opening the real bundled document in a custom `VoiidSheet([.medium,.large])` with Done/drag/back/scrim dismissal, "I already have an account" removed from screen and flow; `LegalDocumentScreen.kt` extracts reusable `LegalDocumentBody`; `OnboardingPrimaryButton` gains an enabled gate.
    - Foundation: new `ui/components/VoiidSheet.kt` — custom non-Material sheet primitive (detents incl. fixed/medium/large/content, initial detent, optional 40×4 handle, direct finger tracking, velocity settle, drag-to-dismiss, nested-scroll handoff, IME lift, reduced-motion fade, async hide-before-callback) backing this and future migrations.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P0 — Align signup/profile field ownership: photo + name + username first; optional email/bio + Skip second; server username validation.
    - Implementation: `SignupScreen.kt` rewritten to the iOS contract — photo picker with pick-time 1024px/5MB enforcement + success/error haptics, name, username with local format rules (3–20 chars, no leading digit) and 400ms-debounced `checkUsername` server validation with idle/checking/available/taken states and stage-true help copy, read-only verified-number row; `CreateProfileScreen.kt` now collects ONLY optional email/bio (120-char limit, loose validity) with privacy note and "Skip for now" that saves the same required fields; single server write incl. photo upload via `MediaService.uploadProfilePhoto` + 409 taken-in-between handling routed back with error haptic. Flow hands an iOS-`ProfileDraft` twin between steps.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P0 — Restore exact six-digit backup PIN validation; add source candidate chooser and staged restoring/retry states.
    - Implementation: `RestoreFlow.kt` rewritten to the iOS model — steps UNLOCK→PHRASE→CHOOSE→RESTORING; candidates loaded from server + Drive (iCloud n/a) sorted newest-first, chooser shown only when >1 exists with Newest badge/empty-state note/add-Drive sign-in; credential held before source choice; restoring page shows the five named stages (unlock/download/decrypt/merge/keys), failures surface there with Try again/Skip (Locked/NoRecoveryKey return to unlock with error), success haptic + 650ms completion hold; onboarding visual primitives replace the settings scaffold; six separate masked PIN boxes gate Continue on EXACTLY six digits (`VOIID_PIN_LENGTH`). Setup/confirm/change-PIN in `BackupRecoveryScreen.kt` now enforce six digits too.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P0 — Pass `role = it.role` while mapping group members; gate owner/admin/remove actions and surface failures.
    - Implementation: `GroupInfoView.kt` now maps `role` and `photoName` from `fetchMembers`, sorts You → owner → admins → alphabetical (iOS ranking); transfer stays owner-only; role toggle reloads from server instead of mutating locally; removal is NO LONGER optimistic — the row leaves only after the MLS remove succeeds, with busy state on the button; server refusals surface via new `onError` callbacks (`Stores.kt`) into an inline error under Members and inside the dialog; destructive Remove moved out of the dismiss slot (Cancel is the dismiss action). Full dialog restyle lands with the VoiidDialog migration.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P0 — Build Communities create flow, detail tabs, host inbox, and working Create button.
    - Implementation: new `CommunityCreateFlow.kt` — five-step wizard (identity with derived auto-handle + categories, privacy with policy cards + dependent members-can-invite lockout, spaces, rules, invite/review) with segmented progress, busy/disabled CTA, server-409 error surfacing; `CommunityService.create` extended to the full 046 body (join_policy/discoverable/category/members_can_invite/extra_channels/rules); Create button now opens the flow and lands on the SERVER's card. `CommunitiesHomeView` detail rebuilt as a tabbed shell — Home (host bar via existing `MessageHostButton`, encryption note), Spaces (`channels()` w/ announcement badges), Events (+ tournaments), Members (`members()` roster with owner/admin badges + host-only pending list), About; host inbox (`CommunityHostInboxView`) lists both-end host threads and hands conversation ids to the Chats tab. New `channels()`/`members()` endpoints in CommunityService.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P0 — Add story hold-to-record video, visible permission/capture errors, and upload-size/transcode enforcement.
    - Implementation: `StoryCameraView.kt` rewritten on CameraX VideoCapture — tap=photo / hold(≥300ms)=video with release-to-stop, 30s cap + elapsed/cap timer pill in error red, shutter shrinks and turns red while recording; H.264 720p capture via QualitySelector so takes land under the caps without a transcode pass; mic included when granted. Capture/permission failures are user-visible dialogs; denied CAMERA shows recovery actions (re-request / gallery fallback) instead of a black preview. `StoryComposerSheet.kt`: camera takes route through the same `prepareFromUri` duration/size gates as gallery picks; image encode now RE-CHECKS the 10MB cap, stepping quality down to q30 before reporting the size honestly.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
    - REMAINING: gallery-picked videos >50MB/>30s are refused with a clear error rather than transcoded down — a full H.264 re-encode pipeline for arbitrary gallery files needs a media-library decision (same trade iOS solves with AVAssetExportSession).
- [x] P0 — Add Map manage-audience “Add People” path and Ghost duration chooser.
    - Implementation: `MapAudienceSheet.kt` ManageBody gains an "Add people" row; `MapTabView.kt` flips the live sheet MANAGE → CHOOSE in place (no dismiss/re-present round trip needed with a single-composable sheet) and confirming persists the newly selected users via `setAudience`. Ghost toggle now opens a duration chooser — For 1 hour / Until tomorrow (local midnight) / Until I turn it off — with the iOS message copy, selection haptics, and an "until HH:mm" expiry line under the toggle for timed ghosts.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P0 — Add account-erasure route or immediately correct Android legal copy that claims it exists.
    - Implementation: BOTH. New `net/DpdpService.kt` files `POST dpdp/requests` (kind=erasure), parsing the server's request row + verbatim note and treating 409 as the already-open success state (iOS parity); `SettingsScreen.kt` gains a "Delete my account" danger row with busy state, a confirmation dialog carrying iOS's exact what-actually-happens copy, outcome dialog ("Erasure request recorded" + server note → sign out + wipe via `session.signOut()`), and failure alert with error haptic — request filed BEFORE local teardown, mirroring iOS ordering; `LegalScreen.kt` copy now points to Settings.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P0 — Add full-screen chat media viewer and expose media tap callbacks.
    - Implementation: new `ui/components/VoiidPhotoViewer.kt` — full-screen black viewer with real cached loading/failure states, pinch zoom + pan (clamped), 2.5× double-tap, direct drag-to-dismiss with backdrop fade, close affordance, reduced-motion snap; `MediaViews.kt` exposes `AsyncMediaImage(onTap)` + shared `loadMediaBitmap` local-first resolver so the viewer never re-downloads; `ChatUI.kt` image bubbles now open the viewer on tap.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P0 — Render ChatStore initial-load failures with retry instead of an empty inbox.
    - Implementation: `ChatsHomeView.kt` now renders `chat.loadError` — a non-destructive retry banner ABOVE cached content when the sync fails but the cache exists (mirrors iOS), and a distinct full "Couldn't load your chats" retry state when the failure lands with nothing cached, so a network error never reads as "No chats yet". Loading/empty/list branches preserved via an explicit state precedence.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P1 — Build `VoiidSheet`; migrate all 23 Material sheet call sites and encode each iOS detent.
    - Implementation: `ui/components/VoiidSheet.kt` (full contract: fixed/medium/large/content detents, initial detent, optional 40×4 handle, direct finger tracking, velocity settle, drag-to-dismiss, nested-scroll handoff, nav-bar insets, IME lift, reduced-motion fade, async hide-before-callback). ALL 23 Material `ModalBottomSheet` sites migrated with per-iOS detents: call-type Fixed(240), Overs Fixed(240), Duel Fixed(360), message-info Medium, shared-media Large, country picker Large no-handle, Game Setup Content+Large with handle, GIF/poll/location/roster/join/audience/viewers/opponents/seats/emoji Medium+Large, creator-handle/edit + MyClips-edit Medium. Story reply rebuilt as Fixed(260) sheet with sent-toast + dismiss-after-success. Grep confirms ZERO remaining ModalBottomSheet / rememberModalBottomSheetState.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P1 — Build `VoiidDialog`; migrate all 18 Material alerts and destructive confirmations.
    - Implementation: new `ui/components/VoiidDialog.kt` — branded surface/radius/stroke/scrim, title/body/action hierarchy with destructive-in-confirm and neutral Cancel only, busy + disabled states, Back/scrim dismissal policy, IME avoidance + scrollable body, rigid press haptic reserved to destructive confirms, plus `VoiidDialogCustom`/`VoiidDialogAction` slot variants for rich bodies. ALL Material `AlertDialog` sites migrated (grep: 0 remaining): delete-chat/message/bulk/clear, capacity, resign, camera error, unlink, withdraw-consent (busy), rotate-PIN, unblock ×2, logout ×3-variant, erasure confirm/outcome/error, contact clear/block/report + not-available + block-failure, Group Info member actions (custom slots), photo-source, stop-all, Ghost duration chooser.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x]] P1 — Replace raw settings/subflow dialogs with `VoiidModalNavigator` so Back preserves hierarchy.
    - Implementation: new `ui/components/VoiidModalNavigator.kt` — string-route back stack hosted in ONE window; Back pops children to their parent and only leaves from the root route. ChatsHomeView's eight sibling full-screen dialog blocks for the settings cluster collapsed into one `VoiidModalHost`: Settings pushes backup/privacy/storage/devices/about/legal as CHILDREN, Storage→Backup now opens ON TOP of Storage (Back returns to Storage, never to Chats), Blocked stacks above Privacy.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.

- [x] P1 — Match bottom nav blur, 22dp icon/indicator metrics, true 1.10 active phase, and ghost badge.
    - Implementation: `RootTabView.kt` TabBar — icons 22dp, indicator 22×3dp; active glyph now runs the TRUE transient 1.10 phase (snap to 1.10 on selection, spring-settle to 1.0; inactive eases back to 0.94) instead of the old no-pop animate; ghosted Map shows a persistent HOLLOW accent ring badge (filled dot stays for visible/unread); bar surface is a translucent custom scrim with centralised `TAB_SURFACE_ALPHA = 0.86f` (documented calibration constant — iOS `.bar` blur specifies no number; real backdrop blur has no Compose equivalent without window-level effects). 180ms page fade untouched.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x]] P1 — Add `VoiidPullRefresh` to every iOS-refreshable Android counterpart.
    - Implementation: new `ui/components/VoiidPullRefresh.kt` — modifier-based custom indicator (no Material visuals): nested-scroll overscroll handoff, finger-tracking translation, armed release past 72dp fires exactly once, parked-while-refreshing, reduced-motion holds the ring instead of spinning. Adopted on Communities home, Moments home, Clips Explore/Following, Creator Profile, My Clips, Linked Devices, Storage, Blocked Contacts (`BackupScaffold` gained a modifier param so settings screens can carry it).
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.

- [x] P1 — Add New Chat/New Group search and day grouping in Call Log.
    - Implementation: new `ui/components/VoiidSearchField.kt` (48dp, 12dp radius, magnifier/clear affordances, focused border, IME Search, debounce hook) wired into `NewChatScreen` (filters names AND numbers, distinct empty-vs-no-match copy) and `NewGroupScreen`; `CallLogScreen` now groups rows by day with Today/Yesterday/weekday/date section headers (via `VoiidDate.separator`) and preserves the 76dp inset divider.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P1 — Add stop-all live-location confirmation and match banner hierarchy/motion.
    - Implementation: `LocationBanner.kt` rewritten to the iOS model — two-line title/time hierarchy on solid primary, accent pulse dot, error-red Stop/Stop-all pill with rigid haptic; Stop-ALL now requires a destructive confirmation dialog (busy state, single-share Stop stays immediate); entrance slides from top + fade, reduced-motion fade-only; bottom hairline divider.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x] P1 — Fix storage/backup error handling, backup date, Backup & Recovery route, logout confirmation, and outcome toast/haptics.
    - Implementation: `BackupRecoveryScreen.kt` — refresh failures now KEEP last-good metadata and show a distinct statusError (no more network-error-becomes-"no backup"); Back up now has busy state, success flash("Backed up") + success haptic + refresh, actionable error + error haptic on failure; setup/PIN completions flash confirmations; auto-dismissing outcome toast banner. `StorageSettingsScreen.kt` — Cloud backup row shows the LAST BACKUP DATE and routes into Backup & Recovery (wired via ChatsHomeView's existing dialog layer); Clear Caches now fires the success haptic. `SettingsScreen.kt` — Log out is CONFIRMED with a three-variant recoverability warning probed from the real recovery-key state (Found → restorable / NotSet → unrecoverable / other → honest unknown), destructive Log out button + Cancel; immediate logout removed.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.
- [x]] P1 — Add safety-number QR after selecting a vetted encoder; add real-image pinch/pan photo viewer.
    - Implementation: added vetted pure-Java ZXing core 3.5.3 (libs.versions.toml); `SafetyNumberScreen.kt` NumberCard is now tap-to-swap digits/QR with HIGH error correction at a crisp 600px raster and graceful failure copy; `ProfilePhotoViewer` accepts the real photo ref and renders through `VoiidPhotoViewer` via the shared local-first `AvatarCache.resolve` (pinch + pan + 2.5× double-tap + drag-dismiss); ContactProfile passes the resolved peer photo.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.

- [x]] P1 — Preserve existing camera takes behind a replace confirmation when importing a clip.
    - Implementation: `ClipCameraView.kt` — the gallery button now checks banked takes: none → straight import; some → destructive `VoiidDialog` naming the count ("This discards your N unmerged take(s).") with Discard & pick / Cancel before the picker launches.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.

- [x] P1 — Replace Game Settings Material `Switch` with `VoiidToggle`.
    - Implementation: `GameSettingsSheet.kt` — the last stock Material `Switch` now renders the custom `VoiidToggle` (branded track/thumb, press haptics); unused Switch imports removed.
    - Verify: `./gradlew :app:compileDebugKotlin` — BUILD SUCCESSFUL.
- [x]] P2 — Add explicit line heights/tracking to semantic Android type styles.
    - Implementation: `Type.kt` — display/title/headline/body/callout/subhead/footnote/caption now carry explicit lineHeight and negative tracking from headline upward (display 34/38/-0.4sp … caption 12/16), following the iOS display-type convention already used on the onboarding title.
    - Verify: `./gradlew :app:compileDebugKotlin` — BUILD SUCCESSFUL.

- [x]] P2 — Align success/error colors and add missing deep/raised/accent state tokens.
    - Implementation: `Color.kt` — Success/Error palettes moved to the iOS values (#238A58/#2FA36B, #D83A40/#E5484D); new composable tokens `surfaceDeep`, `surfaceRaised`, `primaryPressed`, `accentTint`, `accentInk` backed by raw palette values matching iOS Theme.swift.
    - Verify: `./gradlew :app:compileDebugKotlin` — BUILD SUCCESSFUL.

- [x]] P2 — Add AI bubble insertion transition and shared translucent top/input chrome.
    - Implementation: `AIChatView.kt` — header and input bar render on the shared translucent scrim (0.86f, same token family as the tab bar) matching iOS `.ultraThinMaterial`; bubbles insert with a non-vestibular 0.98→1 scale + fade over 140ms.
    - Verify: `./gradlew :app:compileDebugKotlin` — BUILD SUCCESSFUL.

- [x]] P2 — Calibrate shared Compose springs against iOS response/damping specs; remove duplicate haptics.
    - Implementation: new `VoiidMotion` in Components.kt — softPress = response 0.30s/damping 0.6 (stiffness 440), tabPress = response 0.22s/damping 0.7 (stiffness 815), derived (2π/R)² so both platforms draw the same curve; `softClickable` and RootTabView tab press now use them. Duplicate feedback removed on the call-type cards (softClickable's press haptic OR the callback tap — not both).
    - Verify: `./gradlew :app:compileDebugKotlin` — BUILD SUCCESSFUL.

- [x]] P2 — Add reduced-motion coverage to onboarding, sheets, root overlays, Moments, and Clips.
    - Implementation: `OnboardingFlow.kt` — splash handoff is a HARD cut at 1200ms (matches iOS and removes the text-rasterising glide for everyone), step transitions fade instead of slide under Reduce Motion; sheets travel through VoiidSheet which already fades under the setting; story reply/viewers, pull-refresh (ring holds instead of spins) and the AI insertion are gated or opacity-only. Chats list reflow, calls, group calls and games keep their existing gates.
    - Verify: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest` — BUILD SUCCESSFUL.


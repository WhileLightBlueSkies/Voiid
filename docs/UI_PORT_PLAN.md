# UI port — reference design → live iOS app

> **Source of truth for the design:** `/Users/devacc/Voiid Ui` (42 files, ~13,000 lines of
> SwiftUI). It is a standalone mock app: pure UI, mock data, no networking or crypto.
>
> **Target:** `apps/ios/Voiid` — the live app (982 Swift files) with working ChatEngine,
> GroupEngine, ratchet sessions, receipts, and persistence.
>
> **The job:** port the reference's *visual design and flow* onto the live app's *live data*.
> Never the reverse — copying a reference file over a live one deletes the wiring behind it.

Progress is tracked in the tables below. Update the Status column as work lands.

---

## The rule every port follows

The reference screens are backed by mock arrays (`ChatModels.swift`, `CommunityModels.swift`,
`MessageModels.swift`). The live screens are backed by engines that took months to get right —
per-device sessions, TOFU pinning, retry-on-heal, read-receipt rank guards.

So a port is: **take the reference's layout, spacing, hierarchy and interaction; keep every
`@State`, engine call, and async path the live screen already has.** A screen that compiles but
no longer decrypts is a failed port, and it fails silently — which is why each one is built and
checked before moving on.

Three reference files are **models only** and must NOT be ported — they are the mock backing
that the live app replaces with real engines: `ChatModels.swift`, `MessageModels.swift`,
`CommunityModels.swift`. Read them to understand intended shape; port none of them.

---

## Status legend

`✅ done` · `🔧 in progress` · `⬜ todo` · `🆕 new feature (needs backend)` · `⏭️ skip (mock-only)`

---

## Phase 0 — Foundation

| Reference | Live target | Status | Notes |
|---|---|---|---|
| `DesignSystem/Theme.swift` | `DesignSystem/Theme.swift` | ✅ done | Byte-identical already. |
| `DesignSystem/Haptics.swift` | `DesignSystem/Haptics.swift` | ✅ done | Byte-identical already. |
| `DesignSystem/VoiidLogo.swift` | `DesignSystem/BrandMark.swift` | ✅ done | Real vector mark + dotless-ı wordmark; `BrandLogoMark` kept as alias so 7 call sites compile. Build verified. |
| `DesignSystem/Brand.swift` | — | ⬜ todo | Compare against `OnboardingBrandChrome`; may already be covered. |
| `LaunchScreen.storyboard` | `LaunchScreen.storyboard` | ✅ done | Live app had **no launch screen at all** — bare black until SwiftUI mounted. Storyboard + `LaunchLockup`/`LaunchStage`/`LaunchBackground` assets ported, `UILaunchStoryboardName` registered. Verified in bundle. |
| `LogoMark` (splash) | `Onboarding/OnboardingFlow.swift` | ✅ done | Was a wordmark-only placeholder; now `VoiidLockup` (real mark + wordmark). |
| `DesignSystem/AppTheme.swift` | `ThemePreference.swift` | ⬜ todo | Check for divergence in theme switching. |
| `DesignSystem/OnboardingKit.swift` | `OnboardingBrandChrome.swift` | ⬜ todo | 23KB reference vs 389-line live. The shared onboarding skeleton. |
| `DesignSystem/ImageResizing.swift` | — | ⬜ todo | Small utility; check if live has an equivalent. |
| `DesignSystem/Countries.swift` | `Onboarding/Countries.swift` | ⬜ todo | Live version is 76 lines vs 9KB reference — likely a data-set difference. |

**Note on the logo SVG:** the reference and live `voiid-logomark.svg` differ in gradient stops.
**The live one is newer and correct** (commit `da298e0` sampled it from the original raster:
`#457512 → #AAD91E`). Do not overwrite it with the reference's `#5C7A00 → #B8F000`.

---

## Phase 1 — Onboarding (login → terms → profile)

The flow the user asked to start from. Live onboarding was partly rebuilt already in commits
`3f883aa`, `ad1f14c`, `5e2b520` — so several of these are diffs, not rewrites.

| # | Reference | Live target | Status | Notes |
|---|---|---|---|---|
| 1.1 | `TermsScreen` (312) | `WelcomeTermsScreen` (290) | ✅ done (no change) | **Deliberately NOT ported — see note below.** Live already implements the reference design correctly and carries DPDP consent logic the reference lacks. |
| 1.2 | `PhoneNumberScreen` (415) | `PhoneScreen` (254) | ✅ done | Ported `normalise()` (autofill dial-code strip — silent truncation bug), per-country digit bounds (237 ranges), country-change reset, 350ms delayed focus. Firebase send untouched. |
| 1.3 | `CountryPickerSheet` (164) | `CountryPickerSheet` (99) | ⬜ todo | Check the country data set matches. |
| 1.4 | `VerificationScreen` (333) | `OTPScreen` (190) | ⬜ todo | Wired to OTP verify + JWT issue. Preserve auth path. |
| 1.5 | `VerifiedScreen` (202) | — | ⬜ todo | No live counterpart; may be folded into OTP success. |
| 1.6 | `PermissionsScreen` (172) | `PermissionsScreen` (193) | ⬜ todo | Live requests real permissions — preserve. |
| 1.7 | `ProfileSetupScreen` (285) | `CreateProfileScreen` (220) | ⬜ todo | Wired to profile PUT + avatar upload. |
| 1.8 | `ProfileExtrasScreen` (181) | — | ⬜ todo | No live counterpart. Decide: new screen or merge. |
| 1.9 | `RestoreAccountScreen` (335) | `RestoreMessagesView` (151) | ⬜ todo | Touches recovery (`012_recovery.sql`). Careful. |
| 1.10 | `ChooseBackupScreen` (493) | `Settings/BackupRecoveryView` (417) | ⬜ todo | Reference puts this in onboarding; live has it in settings. Resolve placement. |
| 1.11 | `RestoringScreen` (633) | — | ⬜ todo | No live counterpart. Restore progress UI. |
| 1.12 | `HomePlaceholderScreen` (100) | — | ⏭️ skip | Mock-only landing stub. |
| 1.13 | — | `OnboardingFlow` (120) | ⬜ todo | Live flow coordinator — must absorb any new steps above. |

### 1.1 — why Terms was left alone

The reference gates Continue behind a checkbox. The live screen has no checkbox, and that is
correct: every purpose is `LegalDocuments.Purpose.required`, so a box the user cannot untick
misrepresents a choice they do not have. The live header says so explicitly.

The live screen also carries compliance the reference has no concept of, because the reference
is a visual study whose documents do not exist ("the documents themselves do not exist yet"):

- consent recorded LOCALLY at tap time and flushed by `submitPendingConsent()` after signup —
  posting here would process the phone number before consent, the inversion DPDP s.5 forbids
- four real purposes wired to `LegalDocuments`, opening real docs via `LegalDocumentView`
- age confirmation (drawn "14+" glyph, so the threshold cannot silently lie)
- version/build read from the bundle

Both already use the same kit — `OnboardingCard`, `OnboardingPrivacyNote`,
`OnboardingPrimaryButton` — on the same committed-dark ground. **The live screen IS the
reference design, correctly adapted.** Porting the checkbox would trade working DPDP compliance
for a control that misrepresents consent.

**Flow question to settle before 1.9–1.11:** the reference has a fuller restore journey
(RestoreAccount → ChooseBackup → Restoring) than the live app. Decide whether backup/restore
moves into onboarding or stays in settings.

---

## Phase 2 — Shell

| # | Reference | Live target | Status | Notes |
|---|---|---|---|---|
| 2.1 | `RootTabView` (895) | `RootTabView` (442) | 🔧 in progress | Counter-based tab-bar hiding LANDED (6a611a4). Call-state item does not apply — see below. |

Two pieces of architecture in the reference worth adopting, independent of styling:

- **Hide-tab-bar as a COUNT, not a Bool.** A Bool breaks when two screens both want the bar
  hidden: pushing B from A runs B's `onAppear` before A's `onDisappear`, so the outgoing screen
  resets the flag and the bar reappears over the screen that asked to hide it. Lifecycle order
  is not guaranteed; counting makes order irrelevant.
- **Call state lives in the session, not the conversation.** A minimised call must survive the
  user navigating away, so it cannot be owned by the screen that started it.

  **NOT PORTED — the live app already does this, and better.** `CallService` is a singleton
  `ObservableObject` holding `active`, `connectedSeconds`, `remoteVideoTrack` and the audio
  route, so a call outlives every screen by construction; `CallFloatingWindow` and the PiP
  controller both read from it. The `@State activeCall` in ChatDetailView/ChatsHomeView is a
  local sheet trigger, not the call. The reference puts this in the session only because a mock
  has no service layer — moving live call state into `AppSession` would be a downgrade.

Tabs are nearly aligned. Reference: `ai, chats, moments, communities, map, games, clips`.
Live: `ai, chat, stories, communities, map, games, clips`. The real divergence is
**`moments` (Memories) vs `stories`** — see Phase 6.

---

## Phase 3 — Chat core

The highest-risk phase. `ChatDetailView` is wired to the Double Ratchet, per-device sessions,
TOFU pinning, receipts and retry logic — most of the last three months of fixes live in it.

| # | Reference | Live target | Status | Notes |
|---|---|---|---|---|
| 3.1 | `ChatsScreen` (638) | `ChatsHomeView` (882) | ⬜ todo | Also touches `ChatListRows`, `DraggableChatGrid`. |
| 3.2 | `ConversationScreen` (1618) | `ChatDetailView` (1932) | ⬜ todo | **Largest and most delicate. Split across sessions.** |
| 3.3 | `ChatComponents` (136) | `ChatListRows` (165) | ⬜ todo | Shared row/bubble components. |
| 3.4 | `ChatSearchSheet` (136) | — | ⬜ todo | No live counterpart found. |
| 3.5 | `ChatSettingsScreen` (165) | `Settings/SettingsSheet` (564) | ⬜ todo | Per-chat settings vs global — confirm scope. |
| 3.6 | `NewChatSheet` (127) | `NewChatView` (160) | ⬜ todo | Reachability rules apply (`020_reachability.sql`). |
| 3.7 | `CreateGroupSheet` (576) | `NewGroupView` (184) | ⬜ todo | Live creates real MLS groups. Big gap in size. |
| 3.8 | `VoiceRecorder` (219) | `VoiceNote` (350) | ⬜ todo | Live has real recording + encrypted upload. |
| 3.9 | `ContactScreen` (832) | `ContactProfileView` (895) | ⬜ todo | |
| 3.10 | `ProfileSheet` (494) | `GroupInfoView` (293) / `ContactProfileView` | ⬜ todo | Confirm which live screen this maps to. |
| 3.11 | `MessageSentScreen` (164) | — | ⬜ todo | Confirmation screen; may be a sheet in live. |
| — | `ChatModels`, `MessageModels` | — | ⏭️ skip | Mock backing only. |

---

## Phase 4 — Calls

| # | Reference | Live target | Status | Notes |
|---|---|---|---|---|
| 4.1 | `CallScreen` (469) | `CallScreens` (813) | ⬜ todo | Live handles WebRTC/LiveKit state. |
| 4.2 | `VideoCallScreen` (407) | `CallScreens` (813) | ⬜ todo | Reference splits voice/video into two screens deliberately. |
| 4.3 | `GroupCallScreen` (580) | `GroupCallScreen` (462) | ⬜ todo | |
| 4.4 | `GroupVideoCallScreen` (441) | `ConferenceViews` (218) | ⬜ todo | |
| — | minimised pill / PiP | `CallPiPView`, `CallFloatingWindow`, `OngoingCallBanner` | ⬜ todo | Reference drives these from `AppSession` — pairs with 2.1. |

---

## Phase 5 — Communities

Live has the container (`030_communities.sql`) and several views; the reference adds the
member↔host thread flow, which matches the `community_host_threads` design.

| # | Reference | Live target | Status | Notes |
|---|---|---|---|---|
| 5.1 | `CommunitiesScreen` (298) | `CommunitiesHomeView` (281) | ⬜ todo | |
| 5.2 | `CommunityHomeScreen` (515) | `CommunityDetailView` (131) | ⬜ todo | Live is much thinner — real gap. |
| 5.3 | `CommunityInboxScreen` (307) | — | ⬜ todo | Host's inbox of member threads. |
| 5.4 | `CommunityThreadScreen` (341) | — | ⬜ todo | One member↔host thread. |
| 5.5 | `MessageCommunityScreen` (253) | `MessageHostButton` (132) | ⬜ todo | Member composing to host. |
| 5.6 | `ThreadResolvedScreen` (111) | — | ⬜ todo | |
| — | `CommunityModels` (329) | — | ⏭️ skip | Mock backing only. |

**Constraint (`030_communities.sql`):** member→host only, never member→member. The schema has
no column able to name a second member — keep it that way.

---

## Phase 6 — Memories 🆕

| # | Reference | Live target | Status | Notes |
|---|---|---|---|---|
| 6.1 | `MemoriesScreen` (525) | — | 🆕 new feature | No table, no API route, no live screen. |

**This is the only genuinely new product in the set.** Its header states the idea: built around
*time*, not files — a "N years ago" rail with Recent / This Month sections. That is a
resurfacing product, distinct from Stories (`017_stories.sql`, 8 live files), which is
ephemeral broadcast.

Needs, in order: read `docs/research/10_memories.md` first (a design may already exist) →
schema → API route → client. **Do not start this as a UI port**; it is a feature build.

Also settles the tab question in 2.1: does Memories *replace* the Stories tab or sit beside it?

---

## Phase 7 — Clips, profile, settings

| # | Reference | Live target | Status | Notes |
|---|---|---|---|---|
| 7.1 | `ClipsScreen` (323) | `Clips/ClipsFeedView` (553) | ⬜ todo | Live Clips is large and complete (9 files, ~5,000 lines). |
| 7.2 | `SocialProfileScreen` (585) | `Clips/CreatorProfileView` (504) | ⬜ todo | Creator identity (`029_creator_profiles.sql`). |
| 7.3 | `EditProfileScreen` (616) | `Settings/EditProfileView` (406) | ⬜ todo | |
| 7.4 | `LinkedDevicesScreen` (492) | `Settings/LinkedDevicesView` (320) | ⬜ todo | Device linking = crypto. Preserve carefully. |

---

## Build order, and why

1. **Phase 0** — everything renders these tokens.
2. **Phase 1 (onboarding)** — the user's stated starting point, and the lowest-risk real
   screens: little crypto, mostly presentation.
3. **Phase 2 (shell)** — must precede tab screens, or every tab gets ported twice.
4. **Phase 3 (chat)** — highest value, highest risk. Slowest phase; expect several sessions.
5. **Phase 4 (calls)** — depends on the shell's session-owned call state.
6. **Phase 5 (communities)** — self-contained.
7. **Phase 6 (Memories)** — a feature build, not a port; needs backend first.
8. **Phase 7 (clips/profile/settings)** — leaf screens, safe to do last.

## Verification

Every screen: `xcodebuild -scheme Voiid -destination 'platform=iOS Simulator,name=iPhone 16'`
must succeed before moving on. A UI port cannot be verified by compilation alone — for chat and
calls, a two-device send/receive check is the real gate, per the ROADMAP's existing standard.

## Counts

42 reference files → 3 mock-only (skip), 1 new feature, 3 already done, **35 to port**.

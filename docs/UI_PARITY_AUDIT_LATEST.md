# Master UI Parity Audit: iOS (SwiftUI) vs Android (Jetpack Compose)

**Audit Date**: September 18, 2026  
**Git Baseline**: Commit `db4f6204` / `b5612600` (Branch `main`)  
**Test Account Identity**: `@priyanshu` | Phone `+91 6351822668` | OTP `123456` | VPIN `621311`  
**Execution Environment**:
- **iOS Simulator**: `iPhone 17 Pro` (UDID `09E77941-F0D0-482D-96B5-9C3956CE0E15`, iOS 18.2)
- **Android Emulator**: `Medium Phone` (`emulator-5554`, API 37, Android 16)
- **Scope**: Pixel-by-pixel, line-by-line, word-by-word visual and behavioral audit across all screens, navigation architectures, typography, design tokens, micro-animations, haptics, and gestures.

---

## 1. Executive Summary & Critical Architectural Gaps

Following commit `b5612600` (`feat(android): bring Android UI to parity with deep iOS update`) and the latest pulls on `main`, Android received foundational structural updates. However, running both platforms live side-by-side with identical account data reveals **critical architectural, behavioral, and aesthetic divergences**.

### The 7 Critical Divergences & Blockers

1. **Broken 1-on-1 Chat Creation Flow on Android (Functional Bug)**:
   - On iOS, `[ + New chat ]` is permanently visible in the home header's second row, allowing users to start conversations anytime.
   - On Android `ChatsHomeView.kt`, `onNewChat` is **only wired inside `ChatsEmptyState`**. Once a single chat exists on the device, the Android user **literally has no UI button to start a new 1-on-1 chat from the home screen**.
2. **Home Header Architecture (Two-Row Navigation vs Flattened Search)**:
   - **iOS**: Two-row header. Row 1 features user avatar with green presence dot, centered ink `Voiid` wordmark with teal dots, search circle button (`🔍`), and overflow circle button (`•••`). Row 2 features large bold screen title (`"Chats"` / `"Groups"`), teal capsule pill `[ + New chat ]`, and layout toggle `[ 㗊 ]` / `[ ≡ ]`.
   - **Android**: Single-row header. Avatar (no presence dot), giant inline search input `[ 🔍 Search ]`, and 3-dot overflow menu. It completely lacks the `Voiid` wordmark, the title row, the `+ New chat` accent pill, and the Grid/List layout toggle.
3. **Message Long-Press Context Menu & Reactions**:
   - **iOS**: Native UIKit `UIContextMenuInteraction` with full-screen hardware frosted backdrop blur behind the lifted bubble. Floating reaction palette (`👍 ❤️ 😂 😮 😢 🙏 +`) sits gracefully above the bubble with spring physics. Action menu items have icons on the **LEFT** (leading).
   - **Android**: Custom Compose `DropdownMenu` popup. Action icons are aligned on the **RIGHT** (trailing). The reaction palette is crammed inside the top of the menu box rather than floating above the bubble. Scrim is a flat dim with **zero backdrop blur**.
4. **Settings & Identity Block Disconnect**:
   - **iOS**: Identity block contains profile photo (84pt), name, `@username`, phone, presence status, and two stroked buttons: `[ Edit profile ]` (capsule) and `[ 㗊 ]` (QR square). Quick actions strip below contains `Edit profile`, `Share profile`, and `Account center` (with amber `UnwiredDot()`).
   - **Android**: Identity card is a clickable list row with chevron `>`. Quick actions strip contains `Edit profile`, `Share profile`, and duplicate `My QR code`.
5. **Edit Profile Screen Structure & Compliance**:
   - **iOS**: Back button in white circle; `"Save"` button in top navigation bar. Large bold title **"Edit Profile"**, subtitle *"Your name, photo and handle, as everyone you chat with sees them."*, badge `[ 🛡️ End-to-end encrypted ]`. Every field has a circular icon container on the left (`[ 👤 ]`, `[ @ ]`, `[ ☰ ]`, `[ 📞 ]`). Danger zone has red trash icon, subtitle, and detailed legal explanatory footer.
   - **Android**: Centered title `"Edit profile"`. No Save in top bar (Save is a bottom pill). No large title, no subtitle, no encryption badge. Fields lack icon containers. Copy uses `"Bio"` instead of `"About"` and `"Phone number"` instead of `"Phone"`. Danger zone has plain text without subtitle or explanatory footer.
6. **Group Info Screen Architecture**:
   - **iOS**: Overlapping 3-avatar cluster pyramid of real member photos. 3 quick action cards: `[ 💬 Message ]`, `[ 📞 Voice ]`, `[ 📹 Video ]`. Clean navigation rows (`Shared media >`, `Notifications >`, `Verify encryption >`). Member badges are Title Case outline pills (`Owner`, `Admin`).
   - **Android**: Giant flat gray circle with `"voiid"` watermark. Zero quick action cards. Inline scroll card for media. Lowercase solid pills (`owner`, `admin`). Missing "Verify encryption" row.
7. **New Group Creation Screen**:
   - **iOS**: Centered squircle card with `person.3.fill` icon (88x88pt), bold headline `"A space for your people"`, subtitle *"Choose a name and add people to start your private group."*. Horizontal scrolling strip of selected member avatars with `xmark` remove buttons. Full-width bottom action button `[ Create group ]`.
   - **Android**: Plain form starting directly with text input. No hero icon, no headline, no subtitle. No horizontal avatar strip. Tiny text button `"Create"` in the top navigation bar.

---

## 2. Design Tokens, Geometry, Physics & Typography Matrix

| Design Attribute | iOS SwiftUI (`Theme.swift`) | Android Jetpack Compose (`Theme.kt`, `Color.kt`) | Status | Parity Gap & Required Alignment |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Brand Teal** | `VoiidColor.primary` = `#13828C` (Voiid Tide, fixed in light & dark) | `VoiidPalette.PrimaryLight` = `#13828C`<br>`VoiidPalette.PrimaryDark` = `#78AAAD` | ⚠️ Divergent | Android lifts primary to `#78AAAD` in dark mode, which lowers contrast on white-text buttons. Must pin `#13828C`. |
| **Page Ground** | Light: `#F6F8F8`<br>Dark: `#14191C` | Light: `#F6F8F8`<br>Dark: `#14191C` | ✅ Exact Match | Identical hex values. |
| **Card Surface** | Light: `#FFFFFF`<br>Dark: `#1B2226` | Light: `#FFFFFF`<br>Dark: `#1B2226` | ✅ Exact Match | Identical hex values. |
| **Elevated Surface** | Light: `#EDF1F1`<br>Dark: `#232C30` | Light: `#EDF1F1`<br>Dark: `#232C30` | ✅ Exact Match | Identical hex values. |
| **Dividers & Borders** | Light: `#D7DEDF`<br>Dark: `#263236` | Light: `#D7DEDF`<br>Dark: `#263236` | ✅ Exact Match | Identical hex values. |
| **Sent Bubble Fill** | `#13828C` (White text, AA 4.57:1) | `#13828C` (White text) | ✅ Exact Match | Identical hex values. |
| **Received Bubble Fill**| Light: `#EDF1F1`<br>Dark: `#232C30` | Light: `#EDF1F1`<br>Dark: `#232C30` | ✅ Exact Match | Identical hex values. |
| **Corner Geometry** | Continuous Superellipse (`style: .continuous`) | Standard Circular Fillets (`RoundedCornerShape`) | ❌ Discrepancy | Android corners feel "boxy" and sharp. Needs squircle cubic bezier curvature. |
| **Surface Glass** | Native `.bar` & `.ultraThinMaterial` hardware convolution blur | Flat semi-opaque surface (`0.86f` alpha), no convolution blur | ❌ Discrepancy | Android lacks backdrop blur and specular rim highlight. |
| **Spring Physics** | Response `0.32s`, damping `0.86`, interactive drag tracking | Standard Compose `spring()` and linear transitions | ⚠️ Motion Gap | iOS transitions feel physically weighted and organic. |
| **Haptic Feedback** | CoreHaptics (`.rigid`, `.soft`, `.medium`, `.heavy`, `.selection`) | Android `Vibrator` / `HapticFeedbackConstants` | ⚠️ Sensory Gap | Android haptics feel generic; need tailored short tick waveforms. |
| **Typography** | SF Pro Rounded (Display, Title, Headline, Body) | Roboto / System Default with rounded style | ⚠️ Font Gap | SF Pro Rounded has distinctive soft geometric stroke terminals. |

---

## 3. Screen-by-Screen, Line-by-Line, Word-by-Word Parity Audit

---

### 3.1 Tab Bar & App Shell Navigation

| Screen Element | iOS SwiftUI (`RootTabView.swift`) | Android Jetpack Compose (`RootTabView.kt`) | Status | Word-by-Word / Behavioral Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Visible Tabs** | `Chats`, `Moments`, `Communities`, `Games` | `Chats`, `Moments`, `Communities`, `Games` | ✅ Match | 4 active tabs visible on both platforms. |
| **Tab 1: Chats** | Label: `"Chats"`<br>Icons: `"bubble.left.and.bubble.right"` / `.fill` | Label: `"Chats"`<br>Icons: `Icons.Outlined.ChatBubbleOutline` / `Filled` | ⚠️ Minor | iOS uses dual overlapping bubbles; Android uses single bubble. |
| **Tab 2: Moments** | Label: `"Moments"`<br>Icons: `"circle.dashed"` / `"circle.circle.fill"` | Label: `"Moments"`<br>Icons: `Icons.Outlined.Circle` / `Icons.Filled.Album` | ⚠️ Minor | iOS uses concentric status rings; Android uses Album icon. |
| **Tab 3: Communities** | Label: `"Communities"`<br>Icons: `"person.3"` / `.fill` | Label: `"Communities"`<br>Icons: `Icons.Outlined.Groups` / `Filled` | ✅ Match | Glyphs and labels match. |
| **Tab 4: Games** | Label: `"Games"`<br>Icons: `"gamecontroller"` / `.fill` | Label: `"Games"`<br>Icons: `Icons.Outlined.SportsEsports` / `Filled` | ✅ Match | Glyphs and labels match. |
| **Bar Background** | `.background(.bar)` with specular rim line | `.background(VoiidColor.background.copy(alpha = 0.86f))` | ❌ Disparity | iOS has real-time frosted hardware blur. Android is flat semi-opaque. |
| **Tab Indicator** | Elastic travel distance stretch: `min(1.25 + distance * 0.28, 2.2)` | Directional spring (fixed width `22.dp`) | ⚠️ Motion Gap | iOS pill stretches proportionally across spanned tabs. |
| **Full-Screen Swipe** | `TabSwipeNavigation`: Horizontal drag transitions tabs | None (Tap only) | ❌ Missing | Android users cannot swipe left/right between tabs. |

---

### 3.2 Chats Home Screen & Subtabs (Chats / Groups)

| Screen Element | iOS SwiftUI (`ChatsHomeView.swift`) | Android Jetpack Compose (`ChatsHomeView.kt`) | Status | Word-by-Word / Behavioral Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Header Row 1** | Avatar with green presence dot + Centered ink `Voiid` wordmark with teal dots + Search circle button (`🔍`) + Overflow circle button (`•••`) | Profile avatar (no presence dot) + Giant inline search box `[ 🔍 Search ]` + Overflow button (`︙`) | ❌ Severe Gap | Android completely flattens header, omitting `Voiid` wordmark and individual action circles. |
| **Header Row 2** | Large bold title (`"Chats"` / `"Groups"`) + Teal capsule pill `[ + New chat ]` + Layout toggle `[ 㗊 ]` / `[ ≡ ]` | **Completely absent on Android** | ❌ Severe Gap | Android has no title row, no new chat button on home, and no grid/list toggle. |
| **New Chat Action** | Permanently available in Row 2: `[ + New chat ]` | **Only wired in empty state!** | 🚨 Critical Bug | Android user cannot start a 1-on-1 chat once any conversation exists. |
| **Layout Modes** | Persisted toggle between 2-column Card Grid and 1-column List view | 2-column Card Grid only | ❌ Missing | Android has no single-column List view implementation. |
| **Subtab Capsule** | Floating segmented pill (`Chats` \| `Groups`) with animated slider | Segmented pill (`Chats` \| `Groups`) | ⚠️ Polish | iOS slider has smooth interactive spring animation. |
| **Card Hold Action** | Circular progress ring fills over 400ms on hold. Sheet: `Call`, `Pin`, `Mute`, `Delete`. | Circular progress ring fills on hold with vibration. | ✅ Match | Both implement hold-to-act progress gesture. |
| **Chats Empty State** | Title: `"No chats yet"`<br>Subtitle: `"Start a conversation with someone in your contacts, or find them by @username."`<br>Buttons: `[ New chat ]`, `[ Find by @username ]`, `[ Open Note to Self ]` | Title: `"No chats yet"`<br>Subtitle: `"Start a conversation with someone in your contacts, or find them by @username."`<br>Buttons: `[ New chat ]`, `[ Find by @username ]` | ⚠️ Missing Action | Android omits `"Open Note to Self"` button. |
| **Groups Empty State**| Title: `"No groups yet"`<br>Subtitle: `"Groups you create or get added to will appear here."`<br>Action: Offers `[ New group ]` button | Title: `"No groups yet"`<br>Subtitle: `"Groups you create or get added to will appear here."`<br>Action: **Container is empty (`if (!isGroups)`)** | ❌ Dead End | Android leaves user on dead end with no creation button. |

---

### 3.3 Chat Detail & Message Actions (Direct & Group)

| Screen Element | iOS SwiftUI (`ChatDetailView.swift` + `MessageContextMenu.swift`) | Android Jetpack Compose (`ChatUI.kt`) | Status | Word-by-Word / Behavioral Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Top App Bar** | Circular white back card `<`. Group: Overlapping avatar cluster. Direct: Profile photo. Title + subtitle. Call actions: `( 📞 \| 📹 )` pill with vertical divider. | Bare back arrow. Title + subtitle. Call actions: Undivided light gray pill. | ⚠️ Polish Gap | iOS has distinct circular back card and hairline-divided call pill. |
| **Encryption Notice** | `[ 🔒 End-to-end encrypted  > ]` with right chevron (tappable to view Safety Number). | `[ 🔒 End-to-end encrypted ]` without chevron (non-interactive). | ⚠️ Polish Gap | Android encryption pill lacks interactive affordance. |
| **Message Bubbles** | Sent: `#13828C` (Tide) with white text. Received: `#232C30` with `#DDE3E4` text. Continuous squircles (`16pt`). | Sent: `#13828C` with white text. Received: `#232C30` with `#DDE3E4` text. `RoundedCornerShape(16.dp)`. | ✅ Colors Match<br>⚠️ Geometry Gap | Continuous squircle curvature on iOS vs circular fillets on Android. |
| **Long-Press Menu** | Native UIKit `UIContextMenuInteraction` with 3D bubble lift, ambient shadow, and hardware backdrop blur. | Compose `DropdownMenu` popup anchored to bubble. Flat opaque box, no backdrop blur. | ❌ Major Disparity | Android message actions feel flat and disconnected. |
| **Reaction Bar** | Floating pill above lifted bubble: `👍 ❤️ 😂 😮 😢 🙏 +`. Spring scale bounce animation on tap. | Horizontal row jammed inside the top of the menu box. Tap-to-react. | ❌ UX Gap | iOS reaction palette floats above bubble; Android is inside dropdown menu. |
| **Menu Action Icons** | Icons are on the **LEFT** (leading edge):<br>`[ ↩️ Reply ]`<br>`[ ↪️ Forward ]`<br>`[ 📄 Copy ]`<br>`[ ℹ️ Info ]`<br>`[ 🔘 Select ]`<br>`[ 🗑️ Delete ]` | Icons are on the **RIGHT** (trailing edge):<br>`[ Reply ↩️ ]`<br>`[ Forward ↪️ ]`<br>`[ Copy 📄 ]`<br>`[ Info ℹ️ ]`<br>`[ Select 🔘 ]`<br>`[ Delete 🗑️ ]` | ❌ Alignment Gap | Android aligns icons on right; iOS aligns on left. |
| **Bottom Input Bar** | Circular `(+)` button, pill field with `"Message"`, trailing camera icon, teal circle mic button with white icon. | Borderless `+` icon, pill field with emoji and camera icons, light teal circle with dark teal mic icon. | ⚠️ Styling Gap | iOS mic button has solid primary fill with white icon; Android has light fill with dark icon. |
| **Swipe to Reply** | Horizontal pan gesture with resistance curve (`dx * 0.55`, max 58pt) + haptic release trigger. | Drag gesture detector on message bubble. | ✅ Match | Both support swipe-to-reply gesture. |
| **Media Viewer** | **`ChatMediaViewer.swift`**: Full UIKit paging controller. Multi-photo swipe, pinch zoom, drag-to-dismiss, bottom thumbnail filmstrip, jump-to-message. | **`VoiidPhotoViewer.kt`**: Single-photo dialog viewer. No multi-photo pager, no bottom filmstrip. | ❌ Severe Functional Gap | Android cannot page through conversation photos or see a thumbnail filmstrip. |

---

### 3.4 Group Info Screen

| Screen Element | iOS SwiftUI (`GroupInfoView.swift`) | Android Jetpack Compose (`GroupInfoView.kt`) | Status | Word-by-Word / Behavioral Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Group Avatar** | `LiveGroupAvatar(members: members, size: 88)`: Overlapping 3-avatar pyramid of real member photos. | Single 88.dp circle with flat `VoiidWordmark` watermark (alpha 0.25f). | ❌ Visual Disconnect | Android shows flat watermark instead of member avatars. |
| **Title & Subtitle** | Title: 27pt rounded bold.<br>Subtitle: `"${members.count} members · Private group"`. | Title: 22sp rounded bold.<br>Subtitle: `"Group · ${members.size} members"`. | ⚠️ Copy Disparity | iOS explicitly states `"Private group"`. |
| **Quick Action Cards**| 3 cards beneath avatar:<br>`[ 💬 Message ]`<br>`[ 📞 Voice ]`<br>`[ 📹 Video ]` | **Completely absent on Android**. | ❌ Missing on Android | Android users have no quick call/message shortcuts on Group Info. |
| **Navigation Rows** | Grouped card with 3 clean rows:<br>1. `"photo.on.rectangle"`: `"Shared media"` (`"Photos, links & files"`)<br>2. `"bell"`: `"Notifications"` (`"Muted"` / `"All messages"`)<br>3. `"lock.shield"`: `"Verify encryption"` (`"Compare security codes with members"`) | Replaces with an inline horizontal scroll card `"Media, links & docs"`. Moves Mute to a bottom switch toggle. Missing `"Verify encryption"` entirely. | ❌ Structural Disconnect | iOS uses clean navigation doors; Android embeds horizontal media preview and omits encryption verification. |
| **Members Section** | Header: `"MEMBERS · ${members.count}"` (11pt semibold uppercase, tracking 1.2).<br>Footer: `Label("Only group members can read messages and listen to calls.", systemImage: "lock.fill")`. | Header: `"${members.size} members"`.<br>Footer: **Completely absent**. | ⚠️ Polish & Privacy Gap | Android lacks privacy reassurance footer. |
| **Member Badges** | Title Case outline pills (`Owner`, `Admin`) with hairline border. | Lowercase solid teal pills (`owner`, `admin`). | ⚠️ Styling Gap | iOS uses elegant outline pills; Android uses solid pills. |
| **Bottom Actions** | Actions accessed cleanly via member tap dialogs. | Card at bottom with `"Exit group"` and `"Report group"`. | ⚠️ Architecture Gap | Layout differences in action placement. |

---

### 3.5 Creation & Discovery Sheets

| Screen / Modal | iOS SwiftUI | Android Jetpack Compose | Status | Detail & Parity Divergence |
| :--- | :--- | :--- | :--- | :--- |
| **New Chat Sheet** | Modal sheet with title `"New Chat"`, search input, contact list, and quick actions (`New group`, `Find by @username`, `Scan QR code`). | Menu triggers individual screens; lacks unified contact discovery sheet. | ⚠️ Architecture Gap | iOS provides unified discovery sheet. |
| **New Group Flow** | **Hero Header**: 88x88pt rounded card with `person.3.fill`, headline `"A space for your people"`, subtitle *"Choose a name and add people to start your private group."*<br>**Selected Member Strip**: Horizontal avatar strip with `xmark` remove buttons.<br>**Create Button**: Prominent bottom pill `[ Create group ]`. | **Hero Header**: Missing completely. Form starts directly with text box.<br>**Selected Member Strip**: Missing; only shows text `"${selected.size} selected"`.<br>**Create Button**: Tiny disabled text button `"Create"` in top navigation bar. | ❌ Severe UX Gap | iOS feels premium, welcoming, and intuitive; Android feels like an unstyled developer form. |
| **Find by Username** | Presented as a sheet modal with `Close` and `Find` in nav bar. Helper text sits *below* input field. | Full-screen push page with back arrow. Helper text sits *above* field. `Find` button is embedded inside input box. | ⚠️ Layout Discrepancy | Presentation and layout positions differ. |
| **Scan QR Code** | Viewfinder overlay with corner brackets, torch toggle button, and library photo picker. | Viewfinder overlay with camera feed and corner brackets. | ✅ Match | Core scanning experience aligned. |
| **Calls Log Screen** | Centered `"Calls"` with `+` circular button.<br>Empty State Copy: *"Your calls and recovered missed calls will appear here."* | Left-aligned `"Calls"`.<br>Empty State Copy: *"Calls you make and receive on this device will appear here."* | ⚠️ Copy Disparity | Text divergence in empty state. |

---

### 3.6 Moments Tab

| Screen Element | iOS SwiftUI (`MomentsHomeView.swift`) | Android Jetpack Compose (`MomentsHomeScreen.kt`) | Status | Word-by-Word / Behavioral Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Header** | Centered `"Moments"`. Right circular button `[ 🗄️ ]` (archive / inbox). | Left-aligned `"Moments"`. No trailing button. | ⚠️ Action Missing | Android lacks archive / inbox button in Moments header. |
| **"Your moment" Card** | Full card container with rounded border. Circle avatar displays **actual user photo** with teal `+` badge. Title: `"Your moment"`, subtitle: `"Add to your moment"`. | Uncontained row directly on page background. Avatar displays placeholder initials `"YM"` even when user has a real photo. | ❌ Visual Defect | Android fails to render user's photo and lacks container card styling. |
| **Empty State Icon** | Dashed circular ring icon above empty state copy. | No icon above empty state copy. | ⚠️ Polish Gap | iOS includes empty state glyph. |
| **Empty State Copy** | *"Share a photo or video with your contacts. It disappears after 24 hours."* | *"Share a photo or video that disappears in 24 hours."* | ⚠️ Copy Disparity | Android omits *"with your contacts. It"*. |
| **Floating Button** | Circular teal FAB with `+` icon positioned above tab bar. | Circular teal FAB with `+` icon. | ✅ Match | Identical FAB styling and position. |

---

### 3.7 Communities Tab

| Screen Element | iOS SwiftUI (`CommunitiesHomeView.swift`) | Android Jetpack Compose (`CommunitiesHomeView.kt`) | Status | Word-by-Word / Behavioral Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Header** | Centered `"Communities"`. Right circular white button `[ + ]`. | Left-aligned `"Communities"`. Right circular teal-tinted button `[ + ]`. | ⚠️ Styling Gap | iOS uses centered title with white circular button. |
| **Discover Card** | Square teal compass icon `[ 🧭 ]`.<br>Title: `"Discover communities"`<br>Subtitle: *"Find people building what you build"*<br>Trailing: Chevron `>`. | Generic group icon `[ 👥 ]`.<br>Title: `"Discover communities"`<br>Subtitle: *"Browse public communities"*<br>Trailing: Chevron `>`. | ⚠️ Copy & Icon Gap | Compass icon vs generic group icon; copy differs. |
| **Search Input** | None on root; discovery opens in dedicated modal `CommunityDiscoverSheet.swift`. | Inline search field on root: `[ Find a community ]`. | ⚠️ Architecture Gap | iOS keeps root clean; Android embeds inline search box. |
| **Section Header** | Section title: `"Your communities"`. | No section title. | ⚠️ Visual Hierarchy | Android lacks section header above joined communities. |
| **Community Avatars** | Initials in rounded rectangle containers: `[ DS ]` (light blue bg), `[ VJ ]` (light teal bg). | Generic person group icon `[ 👥 ]` across all communities. | ❌ Polish Gap | Android lacks initials avatar generation for communities. |
| **Verified Badge** | Verified blue checkmark badge `[ 􀇳 ]` right beside community name. | Separate teal text pill `[ Official ]` in row meta. | ⚠️ Visual Gap | iOS places verified check directly beside name. |
| **Handle Display** | Shows `@dbossshed` and `@voiid_jobs` handle on card. | Does NOT display community `@handle`. | ❌ Missing Data | Android omits community handle. |
| **Meta Row** | `[ 🛡️ 3 members ]` or `[ 🌐 3 members ]`. | Plain text `3 members` without shield or globe icon. | ⚠️ Polish Gap | iOS includes privacy indicator icons in member counts. |
| **Joined Pill** | Dark teal capsule pill: `[ Joined ]` (Capital J). | Solid light teal capsule pill: `[ joined ]` (Lowercase j). | ⚠️ Styling Gap | Casing and color tone divergence. |

---

### 3.8 Games Tab

| Screen Element | iOS SwiftUI (`GamesHomeView.swift`) | Android Jetpack Compose (`GamesHomeScreen.kt`) | Status | Word-by-Word / Behavioral Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Header** | User avatar with teal presence dot + Bold title `"Games"` + 3 circular buttons: Trophy (`trophy`), History (`clock.arrow.circlepath`), Sliders (`slider.horizontal.3`). | Left-aligned `"Games"` + 2 buttons: Trophy, Sliders. | ❌ Missing Elements | Android lacks user avatar and History (`clock.arrow.circlepath`) button. |
| **Hero Featured Banner**| Huge interactive carousel banner with game artwork, category pill `"SPORTS"`, title `"Hand Cricket"`, subtitle *"Two players. Play a friend or a bot."*, button `[ Play → ]`, 3 pagination dots. | Small card `"Daily challenge"`, subtitle *"One Snake arena. Same for everyone. Resets at midnight."* with chevron `>`. | ❌ Severe Visual Gap | iOS has rich animated game hero carousel; Android has small daily challenge card. |
| **Categories Filter** | Section title `"Categories"` with horizontal scrollable filter pills: `[ 🏃 Sports ]`, `[ 㗊 Board ]`, `[ 🎮 Quick ]`, `[ 🎮 Strategy ]`. | **Completely absent on Android**. | ❌ Missing on Android | Android lacks category filtering for games. |
| **Games Grid** | Section title `"All Games"`. 2-column cards with game artwork, white bottom drawer with title (`"Hand Cricket"`) and player count (`"2 players"`). | 2-column cards without section title. Some cards show flat teal background with `#` symbol (`Ludo`, `Sea Battle`). | ❌ Polish Gap | Android has placeholder `#` cards and lacks player count metadata drawers. |

---

### 3.9 Settings & Profile Subsystem

| Screen Element | iOS SwiftUI (`SettingsSheet.swift` & Subviews) | Android Jetpack Compose (`SettingsScreen.kt` & Subviews) | Status | Word-by-Word / Behavioral Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Presentation** | Sheet modal with `"Done"` button in top-right. Pushes dedicated child views. | Full-screen page with back chevron `<`. | ⚠️ Presentation Gap | iOS presents Settings as a dismissible modal sheet. |
| **Identity Block** | Profile photo (84pt), Name, `@username`, phone, status, and **two stroked buttons**: `[ Edit profile ]` (capsule) and `[ 㗊 ]` (QR square). | Profile photo (64dp), Name, `@username`, phone. Entire card is a clickable row with chevron `>`. | ❌ Architecture Disconnect | iOS has inline buttons; Android makes entire identity card a push row. |
| **Quick Actions Strip**| 3 equal cards:<br>1. `Edit profile`<br>2. `Share profile`<br>3. `Account center` (with amber `UnwiredDot()`) | 3 equal cards:<br>1. `Edit profile`<br>2. `Share profile`<br>3. `My QR code` | ❌ Discrepancy | iOS moved QR code to identity block to avoid duplicate door; 3rd action is Account Center. Android has duplicate QR code. |
| **Encryption Banner** | `"You're protected with end-to-end encryption"`<br>Subtitle: `"Your chats, calls and data are always private."` Trailing: Chevron `>`. | `"You're protected with end-to-end encryption"`<br>Subtitle: `"Your chats, calls and data are always private."` Trailing: None. | ⚠️ Polish Gap | iOS includes trailing chevron indicating tapability. |
| **Edit Profile: Header**| White circular back button `<`. Top navigation bar `"Save"` button. Large bold title **"Edit Profile"**, subtitle *"Your name, photo and handle, as everyone you chat with sees them."*, badge `[ 🛡️ End-to-end encrypted ]`. | Standard app bar with centered title `"Edit profile"`. No Save button in top bar (Save is a bottom pill). No large title, no subtitle, no badge. | ❌ Severe Visual Gap | iOS follows Apple HIG large title pattern with encryption reassurance. |
| **Edit Profile: Photo**| Circle avatar with camera badge. Centered caption below: *"Your photo saves as soon as you choose it."* | Circle avatar with camera badge. Clickable text link below: `"Change photo"`. | ⚠️ Copy & Flow Gap | Caption explains immediate save behavior on iOS. |
| **Edit Profile: Fields**| Every field has a circular icon container on left (`[ 👤 ]`, `[ @ ]`, `[ ☰ ]`, `[ 📞 ]`).<br>Field 1: `"Name"`<br>Field 2: `"Username"` (live check with checkmark/xmark icon)<br>Field 3: `"About"` (TextField with 1-4 lines limit)<br>Field 4: `"Phone"` (Row labeled `"Number"`, displays phone). | Plain text boxes without circular icon containers.<br>Field 1: `"Name"`<br>Field 2: `"Username"` (text status "Checking…", "Available", "Taken")<br>Field 3: `"Bio"` (labeled Bio instead of About)<br>Field 4: `"Phone number"` (labeled Phone number). | ❌ Visual & Copy Disparity | iOS has circular icon badges and uses `"About"` and `"Phone"`. |
| **Edit Profile: Danger Zone** | Red outlined circle with trash icon.<br>Title: `"Delete my account"` (red)<br>Subtitle: *"Opens an erasure request and signs this device out"*<br>Footer: *"Voiid keeps your account until the request is actioned, so you can still sign in if you change your mind. This iPhone is signed out and wiped straight away."* | Header: `"Danger zone"`.<br>Row with delete icon and text `"Delete my account"`.<br>No subtitle.<br>No explanatory footer text. | ❌ Compliance & UX Gap | Android lacks essential DPDP erasure explanation and legal context. |
| **Log Out Button** | Centered full-width button `[ ↪️ Log out ]` in red text, clean container. | List row item with right chevron `>`. | ⚠️ Styling Gap | iOS renders Log Out as an isolated destructive button card. |
| **Help & Support Diagnostics** | Includes `"Diagnostics"` section with system share intent to export device, OS, and network payloads for support. | **Completely absent on Android**. | ❌ Missing on Android | Support team cannot request structured diagnostics from Android users. |

---

## 4. Prioritized Implementation Blueprint for Android Parity

To bring the Android application to 100% parity with iOS, execute the following 5 phases:

### Phase 1: Critical Functional Fixes & Navigation Shell
1. **Fix Chats Home New Chat Button**:
   - In `ChatsHomeView.kt`, move `onNewChat` out of `ChatsEmptyState` and wire it to a persistent `[ + New chat ]` pill button in the top bar row 2.
2. **Rebuild Chats Home Header**:
   - Implement the two-row header:
     - Row 1: Profile avatar (with green presence indicator), centered `VoiidWordmark` with teal accent dots, search circle button (`🔍`), and overflow circle button (`•••`).
     - Row 2: Screen title (`"Chats"` / `"Groups"`), `[ + New chat ]` pill button, and Grid/List layout toggle (`[ 㗊 ]` / `[ ≡ ]`).
3. **Implement Single-Column List View**:
   - Add single-column list view mode in `ChatsHomeView.kt` mirroring iOS `ChatListRow`.

### Phase 2: Message Context Menu & Interactions
1. **Rebuild Message Long-Press Context Menu**:
   - Replace Compose `DropdownMenu` with a floating popover anchored above/below the bubble.
   - Add hardware background blur scrim via `FLAG_BLUR_BEHIND` / `RenderEffect`.
   - Place the floating emoji reaction pill (`👍 ❤️ 😂 😮 😢 🙏 +`) directly above the lifted message.
   - Align action menu icons to the **LEFT** (leading edge) with exact labels: `Reply`, `Forward`, `Copy`, `Info` (own messages only), `Select`, `Delete` (red).
2. **Build Multi-Photo Pager (`ChatMediaViewer.kt`)**:
   - Implement full-screen `HorizontalPager` with pinch-to-zoom and swipe-down-to-dismiss.
   - Add chronological bottom thumbnail filmstrip.

### Phase 3: Settings & Edit Profile Overhaul
1. **Align Identity Block & Quick Actions**:
   - In `SettingsScreen.kt`, update identity card to include inline stroked buttons: `[ Edit profile ]` (capsule) and `[ 㗊 ]` (QR square).
   - In `QuickActions`, replace duplicate `My QR code` with `Account center` (wearing an amber unwired badge).
2. **Refactor `EditProfileScreen.kt`**:
   - Add `"Save"` button to top app bar; remove bottom full-width button.
   - Add large bold title **"Edit Profile"**, subtitle, and `[ 🛡️ End-to-end encrypted ]` badge.
   - Add circular icon containers to all field cards (`person`, `at`, `text.alignleft`, `phone`).
   - Rename `"Bio"` to `"About"` and `"Phone number"` to `"Phone"` (with row label `"Number"`).
   - Add Danger zone subtitle *"Opens an erasure request and signs this device out"* and full legal explanatory footer.

### Phase 4: Group Info & Creation Flows
1. **Upgrade Group Info Screen**:
   - Replace flat watermark circle with dynamic overlapping member avatar cluster (`LiveGroupAvatar`).
   - Add the 3 quick action buttons: `[ 💬 Message ]`, `[ 📞 Voice ]`, `[ 📹 Video ]`.
   - Replace inline media card with 3 clean rows: `Shared media >`, `Notifications >` (with mute sheet), `Verify encryption >`.
   - Update member badges to Title Case outline pills (`Owner`, `Admin`).
   - Add privacy reassurance footer below members card.
2. **Upgrade New Group Creation Screen**:
   - Add 88x88dp squircle hero card with `person.3.fill` icon, headline `"A space for your people"`, and subtitle *"Choose a name and add people to start your private group."*.
   - Add horizontal scrolling strip of selected member avatars with remove badges.
   - Add prominent bottom `[ Create group ]` button.

### Phase 5: Design Tokens, Moments, Communities & Games
1. **Design Tokens & Geometry**:
   - Pin `VoiidPalette.PrimaryDark` to `#13828C` to prevent low-contrast button text in dark mode.
   - Create and apply `SquircleShape` (continuous superellipse) across all cards, bubbles, and buttons.
   - Implement `Modifier.voiidGlass()` with specular rim highlight for top/bottom bars.
2. **Moments Tab Polish**:
   - Wrap "Your moment" in a card container and render actual user profile photo with teal `+` badge.
   - Add dashed ring empty state icon and align copy: *"Share a photo or video with your contacts. It disappears after 24 hours."*.
   - Add archive / inbox button to header.
3. **Communities Tab Polish**:
   - Use initials in colored rounded rectangles for community avatars.
   - Add verified checkmark badge directly beside verified community names.
   - Display `@handle` and privacy icons (`🛡️`, `🌐`) in member counts.
4. **Games Tab Polish**:
   - Add user avatar and History button to header.
   - Implement hero game carousel banner (`Hand Cricket`) with category badge, subtitle, button, and dots.
   - Add Categories filter pill strip (`Sports`, `Board`, `Quick`, `Strategy`).
   - Add section header `"All Games"` and metadata bottom drawers on game cards.

---

## 5. Verification Checklist

- [ ] Android home screen displays persistent `[ + New chat ]` button and layout toggle.
- [ ] Android home header features `Voiid` wordmark and user presence indicator dot.
- [ ] Message long-press lifts bubble with backdrop blur, floating reaction palette, and left-aligned menu icons.
- [ ] Settings identity block features inline `Edit profile` and `QR` buttons; Quick Actions includes `Account center`.
- [ ] Edit Profile matches iOS typography, field icons, copy (`About`, `Phone`), and Danger zone legal footer.
- [ ] Group Info displays 3-avatar pyramid cluster, 3 action buttons, and verified encryption row.
- [ ] New Group screen features squircle hero header, selected member avatar strip, and bottom create button.
- [ ] Moments renders actual user profile photo and dashed empty state ring.
- [ ] Communities renders initials avatars, verified badges, and `@handles`.
- [ ] Games features animated hero banner, category pills, and complete card artwork.

# Voiid UI Parity Audit: Line-by-Line, Word-by-Word (iOS SwiftUI vs Android Jetpack Compose)

**Audit Date**: September 17, 2026  
**Git Baseline**: Commit `2f7f7529` (Branch `main`)  
**Scope**: Complete visual, structural, textual, and architectural parity review across all surfaces in `apps/ios/Voiid/Voiid/` and `apps/android/app/src/main/java/com/voiid/app/`.

---

## 1. Executive Summary & Root Divergence

### 1.1 The "Full Deep iOS Update" Context
During recent design iterations (`13b1de6a`, `71026656`, `c603d4ec`, `06d5734f`, `9de94262`, `d484e57a`), the iOS codebase was refactored directly against the 42-file **Voiid Ui** reference design. This brought a deep architectural overhaul across iOS:
1. **Continuous Squircle Geometry**: Replaced simple rounded rectangles with Apple-standard continuous superellipses (`RoundedRectangle(cornerRadius: ..., style: .continuous)`).
2. **Native iOS Material Blur**: Replaced opaque and static fills with `.bar`, `.ultraThinMaterial`, and backdrop blur filters.
3. **Hierarchical Navigation Architecture**: Refactored `SettingsSheet` from an overloaded inline form into Apple-style grouped navigation cards pushing dedicated child destinations (`EditProfileView`, `ChatSettingsView`, `HelpAndSupportView`).
4. **Native UIKit Context Menu System**: Lifted chat bubbles into 3D floating previews with background scrim, quick reaction palettes, and system haptics (`MessageContextMenu.swift`).
5. **Full-Screen Media Viewer**: Replaced single-image views with a unified multi-photo horizontal paging viewer, interactive pinch-to-zoom, drag-down dismissal, and a chronological bottom thumbnail filmstrip (`ChatMediaViewer.swift`).
6. **Dedicated Subsystems**: Built out the full 7-screen Map onboarding & live movement subsystem, community discovery sheets, and AI Hub.

### 1.2 Android's Current State
Android was only partially touched during feature-wiring sprints. As a result:
- **Design System Disconnect**: Android still primarily executes on older Material 3 building blocks and legacy Peacock tokens rather than the refreshed **Voiid Tide** design system.
- **Flat Menus**: Context menus on chat bubbles are plain Material `DropdownMenu` popups without 3D lift, frosted background blur, or physical reaction animations.
- **Redundant Root Settings**: Android's `SettingsScreen.kt` retained inline text fields for Name, Bio, and Username on the root screen, while pushing an incomplete `EditProfileScreen.kt` where the username is marked read-only.
- **Dangerous Action Placement**: Android left "Delete my account" directly at the root of `SettingsScreen.kt`, whereas iOS moved it cleanly to the bottom of `EditProfileView` under "Danger zone" to satisfy Apple Human Interface Guidelines and App Store review requirements.
- **Missing Features & Subsystems**: Android completely lacks the multi-photo filmstrip media viewer, the Map onboarding carousel (`MapIntroScreen`, `MapPrivacyScreen`, `MapMoveScreen`, `MapOnboardingFlow`), `CommunityDiscoverSheet`, and the full AI Hub.

---

## 2. Design Tokens, Geometry & Typography Parity

| Token Category | iOS SwiftUI (`Theme.swift`) | Android Jetpack Compose (`Color.kt`, `Theme.kt`) | Parity Status | Required Android Alignment |
| :--- | :--- | :--- | :--- | :--- |
| **Brand Spine (Primary)** | `VoiidColor.primary` = `#13828C` (Voiid Tide, mid-tone teal) | `VoiidPalette.PrimaryLight` = `#13828C`<br>`VoiidPalette.PrimaryDark` = `#78AAAD` | ⚠️ **Divergent in Dark Mode** | iOS keeps `#13828C` fixed across both modes because filled buttons carry white text (4.57:1). Android lifts to `#78AAAD` which lowers button contrast. |
| **Page Ground (Background)** | Light: `#F6F8F8`<br>Dark: `#14191C` | Light: `#F6F8F8`<br>Dark: `#14191C` | ✅ **Match** | Identical hex values. |
| **Card Surface (SurfaceCard)** | Light: `#FFFFFF`<br>Dark: `#1B2226` | Light: `#FFFFFF`<br>Dark: `#1B2226` | ✅ **Match** | Identical hex values. |
| **Elevated Surface (SurfaceRaised)**| Light: `#EDF1F1`<br>Dark: `#232C30` | Light: `#EDF1F1`<br>Dark: `#232C30` | ✅ **Match** | Identical hex values. |
| **Deep Surface (SurfaceDeep)** | Light: `#EDF1F1`<br>Dark: `#14191C` | Light: `#EDF1F1`<br>Dark: `#14191C` | ✅ **Match** | Identical hex values. |
| **Sent Bubble Fill** | `#13828C` (Tide fixed in both) | `#13828C` (Tide fixed in both) | ✅ **Match** | Identical hex values. |
| **Text on Sent Bubble** | `#FFFFFF` (AA 4.57:1) | `#FFFFFF` | ✅ **Match** | Identical hex values. |
| **Received Bubble Fill** | Light: `#EDF1F1`<br>Dark: `#232C30` | Light: `#EDF1F1`<br>Dark: `#232C30` | ✅ **Match** | Identical hex values. |
| **Primary Text** | Light: `#101617`<br>Dark: `#DDE3E4` | Light: `#101617`<br>Dark: `#DDE3E4` | ✅ **Match** | Identical hex values. |
| **Secondary Text** | Light: `#5D696C`<br>Dark: `#A2ADB0` | Light: `#5D696C`<br>Dark: `#A2ADB0` | ✅ **Match** | Identical hex values. |
| **Dividers & Borders** | Light: `#D7DEDF`<br>Dark: `#263236` | Light: `#D7DEDF`<br>Dark: `#263236` | ✅ **Match** | Identical hex values. |
| **Corner Geometry** | Continuous Superellipse (`style: .continuous`) | Standard Circular Fillets (`RoundedCornerShape`) | ❌ **Major Feel Discrepancy** | Android corners feel "boxy" and sharp compared to iOS smooth organic squircles. |
| **Typography Family** | SF Pro Rounded (Display, Title, Headline, Body) | Roboto / System Default with rounded styling | ⚠️ **Visual Difference** | Provide bundled font or Google Font matching rounded geometric curves. |

---

## 3. Engineering Blueprint: Mimicking iOS Native Glass in Jetpack Compose

On iOS, `.bar` and `.ultraThinMaterial` create a physical, frosted glass appearance by real-time hardware convolution blur of the pixels underneath the view, combined with a subtle specular top rim and a translucent tint.

Android does not have an out-of-the-box single `.background(.bar)` modifier in Jetpack Compose, but identical visual fidelity can be achieved using a multi-tiered architecture:

### 3.1 Window-Level Glass (Bottom Sheets, Dialogs & Modals)
When opening a modal bottom sheet, alert dialog, or popup, Android 12+ (API 31+) provides native hardware-accelerated window blurring via `FLAG_BLUR_BEHIND`.

```kotlin
// Set on the Dialog or Modal Window in Android:
fun Window.applyVoiidGlassBlur(blurRadiusDp: Int = 24) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        addFlags(WindowManager.LayoutParams.FLAG_BLUR_BEHIND)
        attributes.blurBehindRadius = (blurRadiusDp * context.resources.displayMetrics.density).toInt()
    }
}
```

### 3.2 In-App Component Glass Modifier (`Modifier.voiidGlass`)
For floating bars (such as the bottom TabBar, top NavigationBar, floating chip buttons, and message action popovers), Compose can compose:
1. **Translucent Frosted Wash**: `VoiidColor.surfaceCard.copy(alpha = 0.76f)` (or `#CC1B2226` in dark mode).
2. **Specular Rim Highlight**: A 1.dp border stroke using a vertical gradient brush that is brighter at the top and falls off at the bottom.
3. **Hardware RenderEffect Blur (Android 12+ / API 31+)**:
   `Modifier.graphicsLayer { renderEffect = RenderEffect.createBlurEffect(20f, 20f, Shader.TileMode.CLAMP).asComposeRenderEffect() }`
4. **Pre-API 31 Fallback**: Multi-stop vertical gradient scrim simulating the frosted specular falloff.

```kotlin
package com.voiid.app.ui.components

import android.graphics.RenderEffect
import android.graphics.Shader
import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.VoiidColor

/**
 * Replicates iOS `.bar` / `.ultraThinMaterial` in Jetpack Compose.
 *
 * Provides a translucent frosted wash, a directional specular highlight border,
 * and hardware convolution blur on API 31+ (Android 12+).
 */
@Composable
fun Modifier.voiidGlass(
    shape: Shape = RoundedCornerShape(16.dp),
    tint: Color = VoiidColor.surfaceCard.copy(alpha = 0.78f),
    specularBorderWidth: Dp = 1.dp,
    blurRadius: Float = 24f,
): Modifier {
    val specularBrush = Brush.verticalGradient(
        colors = listOf(
            Color.White.copy(alpha = 0.22f),
            Color.White.copy(alpha = 0.08f),
            Color.White.copy(alpha = 0.02f)
        )
    )

    val base = this
        .clip(shape)
        .border(specularBorderWidth, specularBrush, shape)
        .background(tint, shape)

    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        base.graphicsLayer {
            // Apply RenderEffect blur on supported hardware
            renderEffect = RenderEffect.createBlurEffect(
                blurRadius,
                blurRadius,
                Shader.TileMode.CLAMP
            ).asComposeRenderEffect()
        }
    } else {
        base
    }
}
```

---

## 4. Screen-by-Screen, Line-by-Line, Word-by-Word Parity Audit

---

### 4.1 Tab Bar & App Shell Navigation

| Attribute / Element | iOS SwiftUI (`RootTabView.swift`) | Android Jetpack Compose (`RootTabView.kt`) | Parity Status | Word-by-Word / Line-by-Line Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Visible Tabs** | `[.chat, .stories, .communities, .games]` | `[CHAT, STORIES, COMMUNITIES, GAMES]` | ✅ **Exact Match** | 4 active tabs visible in test baseline; AI & Map hidden until live. |
| **Tab 1 Label & Icons** | Label: `"Chats"`<br>Outline: `"bubble.left.and.bubble.right"`<br>Filled: `"bubble.left.and.bubble.right.fill"` | Label: `"Chats"`<br>Outline: `Icons.Outlined.ChatBubbleOutline`<br>Filled: `Icons.Filled.ChatBubble` | ⚠️ **Minor Icon Difference** | iOS uses dual speech bubbles; Android uses single Material chat bubble. Copy matches 100%. |
| **Tab 2 Label & Icons** | Label: `"Moments"`<br>Outline: `"circle.dashed"`<br>Filled: `"circle.circle.fill"` | Label: `"Moments"`<br>Outline: `Icons.Outlined.Circle`<br>Filled: `Icons.Filled.Album` | ⚠️ **Minor Icon Difference** | Android uses `Album` for filled moments; iOS uses Apple concentric circles. Copy matches 100%. |
| **Tab 3 Label & Icons** | Label: `"Communities"`<br>Outline: `"person.3"`<br>Filled: `"person.3.fill"` | Label: `"Communities"`<br>Outline: `Icons.Outlined.Groups`<br>Filled: `Icons.Filled.Groups` | ✅ **Exact Match** | Copy and glyph intent identical. |
| **Tab 4 Label & Icons** | Label: `"Games"`<br>Outline: `"gamecontroller"`<br>Filled: `"gamecontroller.fill"` | Label: `"Games"`<br>Outline: `Icons.Outlined.SportsEsports`<br>Filled: `Icons.Filled.SportsEsports` | ✅ **Exact Match** | Copy and glyph intent identical. |
| **Bar Background Material** | `.background(.bar)` | `.background(VoiidColor.background.copy(alpha = TAB_SURFACE_ALPHA))` (`0.86f`) | ❌ **Feel Disparity** | Android uses an opaque-tinted flat surface without backdrop blur. Needs `Modifier.voiidGlass()`. |
| **Bar Height** | `64pt` content height + bottom home indicator safe area inset | `56dp` indicator offset + navigation bars padding | ⚠️ **Layout Metric Gap** | Android bar content is 8dp tighter than iOS, causing icon labels to sit closer to edge. |
| **Selection Motion & Physics** | Stretch scales with distance travelled: `min(1.25 + distance * 0.28, 2.2)`. Spring response `0.32`, damping `0.9`. | Directional asymmetric spring: leading edge fast (`0.82f`), trailing slow (`0.82f`). Width fixed to `22.dp`. | ⚠️ **Motion Gap** | iOS indicator stretches proportionally to how many tabs were crossed. Android only stretches based on direction. |
| **Full-Screen Tab Swipe** | `TabSwipeNavigation`: Interactive horizontal drag gesture across the screen transitions tabs smoothly. | None. Tab change is tap-only; no full-screen swipe between tabs. | ❌ **Missing on Android** | Android users cannot swipe left/right between main tabs. |

---

### 4.2 App Walkthrough & First-Run Spotlight Tour

| Step | Property | iOS (`AppWalkthroughPlan.swift`) | Android (`AppWalkthroughPlan.kt`) | Parity Status |
| :--- | :--- | :--- | :--- | :--- |
| **1. Welcome** | Eyebrow | `"WELCOME TO VOIID"` | `"WELCOME TO VOIID"` | ✅ Exact Word Match |
| | Title | `"Everything starts here"` | `"Everything starts here"` | ✅ Exact Word Match |
| | Message | `"Private conversations, disappearing moments, communities and instant games — organised into four simple spaces."` | `"Private conversations, disappearing moments, communities and instant games — organised into four simple spaces."` | ✅ Exact Word Match |
| | Graphic Asset | `walkthrough_welcome_hero` | `walkthrough_welcome_hero` | ✅ Exact Match |
| **2. Chats** | Eyebrow | `"ENCRYPTED MESSAGING"` | `"ENCRYPTED MESSAGING"` | ✅ Exact Word Match |
| | Title | `"Your people, one tap away"` | `"Your people, one tap away"` | ✅ Exact Word Match |
| | Message | `"Start 1-on-1 chats and group threads secured with quantum-resistant keys. Long-press messages for reactions and quick replies."` | `"Start 1-on-1 chats and group threads secured with quantum-resistant keys. Long-press messages for reactions and quick replies."` | ✅ Exact Word Match |
| | Target Spotlight | `"nav_tab_chats"` | `"nav_tab_chats"` | ✅ Exact Match |
| **3. Moments** | Eyebrow | `"EPHEMERAL STORIES"` | `"EPHEMERAL STORIES"` | ✅ Exact Word Match |
| | Title | `"Share what is happening"` | `"Share what is happening"` | ✅ Exact Word Match |
| | Message | `"Post photo or video stories that disappear automatically after 24 hours. Control your audience and view replies directly in your chats."` | `"Post photo or video stories that disappear automatically after 24 hours. Control your audience and view replies directly in your chats."` | ✅ Exact Word Match |
| | Target Spotlight | `"nav_tab_moments"` | `"nav_tab_moments"` | ✅ Exact Match |
| **4. Communities** | Eyebrow | `"SPACES & CLUBS"` | `"SPACES & CLUBS"` | ✅ Exact Word Match |
| | Title | `"Find your space"` | `"Find your space"` | ✅ Exact Word Match |
| | Message | `"Discover or create public and private communities. Dive into topic channels, voice lounges, and tournament brackets."` | `"Discover or create public and private communities. Dive into topic channels, voice lounges, and tournament brackets."` | ✅ Exact Word Match |
| | Target Spotlight | `"nav_tab_communities"` | `"nav_tab_communities"` | ✅ Exact Match |
| **5. Comm Search** | Eyebrow | `"COMMUNITY SEARCH"` | `"COMMUNITY SEARCH"` | ✅ Exact Word Match |
| | Title | `"Explore & discover"` | `"Explore & discover"` | ✅ Exact Word Match |
| | Message | `"Search for topic spaces by keyword or @handle, explore trending clubs, or start your own public hub in seconds."` | `"Search for topic spaces by keyword or @handle, explore trending clubs, or start your own public hub in seconds."` | ✅ Exact Word Match |
| | Target Spotlight | `"comm_search_bar"` | `"comm_search_bar"` | ✅ Exact Match |
| **6. Games** | Eyebrow | `"INSTANT PLAY"` | `"INSTANT PLAY"` | ✅ Exact Word Match |
| | Title | `"Play together anywhere"` | `"Play together anywhere"` | ✅ Exact Word Match |
| | Message | `"Jump into lightweight multiplayer games with friends with zero downloads. Complete daily challenges and climb leaderboards."` | `"Jump into lightweight multiplayer games with friends with zero downloads. Complete daily challenges and climb leaderboards."` | ✅ Exact Word Match |
| | Target Spotlight | `"nav_tab_games"` | `"nav_tab_games"` | ✅ Exact Match |
| **7. Profile** | Eyebrow | `"YOUR IDENTITY"` | `"YOUR IDENTITY"` | ✅ Exact Word Match |
| | Title | `"Profile & safety"` | `"Profile & safety"` | ✅ Exact Word Match |
| | Message | `"Tap your avatar anytime to view your Safety Number, share your QR code, or jump into settings with one touch."` | `"Tap your avatar anytime to view your Safety Number, share your QR code, or jump into settings with one touch."` | ✅ Exact Word Match |
| | Target Spotlight | `"nav_header_profile"` | `"nav_header_profile"` | ✅ Exact Match |
| **8. Settings** | Eyebrow | `"SETTINGS & PRIVACY"` | `"SETTINGS & PRIVACY"` | ✅ Exact Word Match |
| | Title | `"You stay in full control"` | `"You stay in full control"` | ✅ Exact Word Match |
| | Message | `"Manage double-ratchet keys, linked desktop devices, disappearing message defaults, and export offline backup phrases."` | `"Manage double-ratchet keys, linked desktop devices, disappearing message defaults, and export offline backup phrases."` | ✅ Exact Word Match |
| | Target Spotlight | `"settings_profile_card"` | `"settings_profile_card"` | ✅ Exact Match |
| **9. Complete** | Eyebrow | `"YOU ARE READY"` | `"YOU ARE READY"` | ✅ Exact Word Match |
| | Title | `"Make Voiid yours"` | `"Make Voiid yours"` | ✅ Exact Word Match |
| | Message | `"Explore at your own pace. You can replay this interactive spotlight tour anytime from Settings > Help & Support."` | `"Explore at your own pace. You can replay this interactive spotlight tour anytime from Settings > Help & Support."` | ✅ Exact Word Match |
| | Bottom Action Button | `"Explore Voiid"` | `"Explore Voiid"` | ✅ Exact Word Match |

---

### 4.3 Chats Home Screen & Grid/List UI

| Screen Element | iOS (`ChatsHomeView.swift`) | Android (`ChatsHomeView.kt`) | Parity Status | Word-by-Word / Line-by-Line Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Header Title** | `"Chats"` (26pt rounded bold) | `"Chats"` (26sp rounded bold) | ✅ **Exact Match** | Identical. |
| **Profile Avatar Button** | `ProfileAvatarButton(size: 38)` | `ProfileAvatar(size: 38.dp)` | ✅ **Exact Match** | Both tap to open Settings sheet. |
| **Message Requests Banner** | `"1 message request"` / `"%d message requests"` | `"1 message request"` / `"%d message requests"` | ✅ **Exact Match** | Subtitle, icon (`tray.fill`), and counts match. |
| **Card Geometry** | `RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)` | `RoundedCornerShape(VoiidRadius.lg)` | ⚠️ **Geometry Gap** | iOS uses continuous squircle; Android uses circular fillet. |
| **Card Artwork Hierarchy** | Card *is* the photo: background image fills entire card, name/time/badge overlaid on top. | Card *is* the photo: background image fills entire card, overlaid controls. | ✅ **Match** | Both adopted the Voiid Ui layout. |
| **Hold-to-Act Overlay** | Circular progress ring fills over 400ms on tile hold. Actions: `Call`, `Pin`, `Mute`, `Delete`. | Circular progress ring fills on tile hold with vibration feedback. | ✅ **Match** | Implemented on both platforms. |
| **Empty Chats State** | Title: `"No chats yet"`<br>Message: `"Start a conversation with someone in your contacts, or find them by @username."` | Title: `"No chats yet"`<br>Message: `"Start a conversation with someone in your contacts, or find them by @username."` | ✅ **Exact Match** | Wording matches 100%. |
| **Empty Chats Actions** | Primary: `"New chat"` (`square.and.pencil`)<br>Secondary: `"Find by @username"` (`at`)<br>Note to Self: `"Open Note to Self"` (`bookmark.fill`) | Primary: `"New chat"`<br>Secondary: `"Find by @username"`<br>Note to Self: **Missing** | ⚠️ **Action Gap** | Android omits the "Open Note to Self" quick escape button. |
| **Empty Groups State** | Title: `"No groups yet"`<br>Message: `"Groups you create or get added to will appear here."` | Title: `"No groups yet"`<br>Message: `"Groups you create or get added to will appear here."` | ✅ **Exact Match** | Wording matches 100%. |
| **Empty Groups Actions** | Action Button: Offers `"New group"` button to immediately create a group. | Action Button: **Container is completely empty (`if (!isGroups)`)**. | ❌ **Missing on Android** | Android leaves the user on a dead end with no button to create a group. |

---

### 4.4 Chat Conversation & Message Action Interactions

| Feature / UI Component | iOS (`ChatDetailView.swift` + `MessageContextMenu.swift`) | Android (`ChatUI.kt`) | Parity Status | Word-by-Word / Line-by-Line Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Message Bubbles** | Sent: `#13828C` (Tide) with white text.<br>Received: `#232C30` in dark with `#DDE3E4` text. Continuous squircles (`16pt`). | Sent: `#13828C` with white text.<br>Received: `#232C30` with `#DDE3E4` text. `RoundedCornerShape(16.dp)`. | ✅ **Colors Match**<br>⚠️ **Geometry Gap** | Colors are identical; corner curve on iOS is continuous superellipse. |
| **Long-Press Menu Mechanism** | UIKit `UIContextMenuInteraction` via `UIViewControllerRepresentable`. | Compose `DropdownMenu` popup anchored to bubble. | ❌ **Major Feel Discrepancy** | Android opens a flat, opaque rectangle. iOS performs a native 3D bubble lift with ambient shadow. |
| **Background Effect on Long-Press** | Frosted background scrim + system depth blur behind lifted bubble. | None (standard dim scrim, no blur). | ❌ **Missing on Android** | Needs window-level blur or Compose backdrop layer. |
| **Quick Emoji Reaction Bar** | Top floating pill with 5 quick emojis (`❤️`, `👍`, `😂`, `😮`, `🙏`, `➕ More`). Bouncy spring scale animation on tap. | Horizontal row in dropdown menu. Tap-to-react. | ⚠️ **Animation Gap** | iOS has bouncy scale reaction pill with spring physics; Android is static. |
| **Action: Reply** | Label: `"Reply"`<br>Icon: `"arrowshape.turn.up.left"` | Label: `"Reply"`<br>Icon: `Icons.AutoMirrored.Filled.Reply` | ✅ **Exact Match** | Exact wording match. |
| **Action: Forward** | Label: `"Forward"`<br>Icon: `"arrowshape.turn.up.right"` | Label: `"Forward"`<br>Icon: `Icons.AutoMirrored.Filled.Forward` | ✅ **Exact Match** | Exact wording match. |
| **Action: Copy** | Label: `"Copy"`<br>Icon: `"doc.on.doc"` | Label: `"Copy"`<br>Icon: `Icons.Default.ContentCopy` | ✅ **Exact Match** | Exact wording match. |
| **Action: Info** | Label: `"Info"`<br>Icon: `"info.circle"` (Only shown on sender's own message) | Label: `"Info"`<br>Icon: `Icons.Default.Info` | ✅ **Exact Match** | Exact wording match. |
| **Action: Select** | Label: `"Select"`<br>Icon: `"checkmark.circle"` | Label: `"Select"`<br>Icon: `Icons.Default.CheckCircle` | ✅ **Exact Match** | Exact wording match. |
| **Action: Delete** | Label: `"Delete"` (Destructive red)<br>Icon: `"trash"` | Label: `"Delete"`<br>Icon: `Icons.Default.Delete` | ✅ **Exact Match** | Exact wording match. |
| **Swipe-to-Reply Gesture** | Native horizontal pan gesture with resistance curve (`dx * 0.55`, clamped to `58pt`), haptic trigger on release. | Drag gesture detector on bubble. | ✅ **Match** | Both support swipe to reply. |
| **Media Viewing Experience** | **`ChatMediaViewer.swift`**: Full UIKit paging controller. Multi-photo swipe, pinch zoom, drag-to-dismiss, bottom thumbnail filmstrip, jump-to-message. | **`VoiidPhotoViewer.kt`**: Single-photo dialog viewer. No multi-photo pager, no bottom filmstrip. | ❌ **Severe Functional Gap** | Android cannot page through conversation photos or see a thumbnail filmstrip. |

---

### 4.5 Settings & Profile Hierarchy

| Section / Item | iOS (`SettingsSheet.swift` & `EditProfileView.swift`) | Android (`SettingsScreen.kt` & `ProfileSettingsScreens.kt`) | Parity Status | Word-by-Word / Line-by-Line Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Settings Presentation** | `NavigationStack` in sheet. Root presents clean profile row + quick actions + grouped cards. All edits happen on pushed subpages. | Single long scroll view. Root contains **inline name editing, inline bio editing, inline username checking, and account deletion**. | ❌ **Structural Disconnect** | Android violates the Voiid Ui architecture by jamming the entire profile editor into the root settings list. |
| **Profile Identity Row (Root)** | Displays Avatar, Name, Handle (`@username`). Tapping the row pushes `EditProfileView`. | Displays Avatar with camera overlay, inline `BasicTextField` for Name, inline bio editor, inline username editor. | ❌ **Structural Disconnect** | iOS is a clean profile card; Android is an editable form. |
| **Quick Action 1** | Label: `"QR code"`<br>Subtitle: `"Share your profile link"` | Label: `"QR code"` | ⚠️ Subtitle missing on Android. |
| **Quick Action 2** | Label: `"Share"`<br>Subtitle: `"Send link to friends"` | Label: `"Share"` | ⚠️ Subtitle missing on Android. |
| **Quick Action 3** | Label: `"Lock"`<br>Subtitle: `"Verify safety number"` | Label: `"Lock"` | ⚠️ Subtitle missing on Android. |
| **Encryption Banner** | Label: `"End-to-end encrypted"`<br>Subtitle: `"Signal Protocol v3"` | Label: `"End-to-end encrypted"`<br>Subtitle: `"Signal Protocol v3"` | ✅ **Exact Match** | Text matches 100%. |
| **Group 1: Header** | `"Account"` | `"Account"` | ✅ **Exact Match** | Identical. |
| **Row: Account** | Title: `"Account"`<br>Subtitle: `"Phone, email, username"` | Subsumed into inline root form. | ❌ Displaced on Android. |
| **Row: Privacy & security** | Title: `"Privacy & security"`<br>Subtitle: `"Visibility, blocked contacts, app lock"` | Title: `"Privacy & security"`<br>Subtitle: `"Visibility, blocked contacts, app lock"` | ✅ **Exact Match** | Text matches 100%. |
| **Group 2: Header** | `"Chats & notifications"` | `"Chats & notifications"` | ✅ **Exact Match** | Identical. |
| **Row: Chats** | Title: `"Chats"`<br>Subtitle: `"Chat list layout, appearance"` | Title: `"Chats"`<br>Subtitle: `"Chat list layout, appearance"` | ✅ **Exact Match** | Text matches 100%. |
| **Row: Storage & data** | Title: `"Storage & data"`<br>Subtitle: `"Manage storage, data usage"` | Title: `"Storage & data"`<br>Subtitle: `"Manage storage, data usage"` | ✅ **Exact Match** | Text matches 100%. |
| **Row: Notifications** | Trailing row below card: `"Notifications"` (opens system app notification settings). | Trailing row: opens Android Notification Channel settings. | ✅ **Match** | Both hand off to system settings. |
| **Group 3: Header** | `"Voiid ecosystem"` | `"Voiid ecosystem"` | ✅ **Exact Match** | Identical. |
| **Row: Backup & Recovery** | Title: `"Backup & Recovery"`<br>Subtitle: Dynamic `backupDetail` (e.g. `"On · Synced 2m ago"` or `"Not backed up"`). | Title: `"Backup & Recovery"`<br>Subtitle: Static `"Encrypted backup & restore"`. | ⚠️ **Dynamic State Gap** | iOS shows live backup status; Android shows static copy. |
| **Row: Devices** | Title: `"Devices"`<br>Subtitle: `"Linked devices, sessions"` | Title: `"Devices"`<br>Subtitle: `"Linked devices, sessions"` | ✅ **Exact Match** | Text matches 100%. |
| **Group 4: Header** | `"Support & more"` | `"Support & more"` | ✅ **Exact Match** | Identical. |
| **Row: Help & support** | Title: `"Help & support"`<br>Subtitle: `"FAQ, contact us"` | Title: `"Help & support"`<br>Subtitle: `"FAQ, contact us"` | ✅ **Exact Match** | Text matches 100%. |
| **Row: Privacy & Legal** | Title: `"Privacy & Legal"`<br>Subtitle: `"Notice, terms, withdraw consent"` | Title: `"Privacy & Legal"`<br>Subtitle: `"Notice, terms, withdraw consent"` | ✅ **Exact Match** | Text matches 100%. |
| **Row: About Voiid** | Title: `"About Voiid"`<br>Subtitle: `"Version, terms, privacy policy"` | Title: `"About Voiid"`<br>Subtitle: `"Version, terms, privacy policy"` | ✅ **Exact Match** | Text matches 100%. |
| **Log Out Button** | Isolated red card at bottom of scrollview:<br>Title: `"Log Out"`<br>Subtitle: `"Sign out of this device"` | Isolated card at bottom:<br>Title: `"Log Out"`<br>Subtitle: `"Sign out of this device"` | ✅ **Exact Match** | Text and destructive style match. |
| **Delete Account Placement** | **Inside `EditProfileView`** under separate `"Danger zone"` section.<br>Reason: App Store review guideline compliance; keeps two destructive buttons off one screen. | **Directly on root `SettingsScreen`** in a red `dangerCard` right above Log Out. | ❌ **Severe UX & Compliance Discrepancy** | Android violates HIG by placing two permanent destructive actions on the same root view. Must move to `EditProfileScreen`. |
| **Edit Profile: Username Field**| Allows live editing with 400ms debounced async check (`ProfileService.checkUsername`). Shows `"Available"` in teal, `"Taken"` in red. | `EditProfileScreen.kt` marks Username as **READ-ONLY** (`"This is what your QR code and profile link point to"`). | ❌ **Functional Parity Inversion** | Android users cannot change their username in the Edit Profile screen. |
| **Help & Support: Diagnostics** | Contains dedicated `"Diagnostics"` section with `ShareLink` allowing users to export version, OS, device, and network diagnostic payload. | **Completely absent**. Android has no Diagnostics section or share action. | ❌ **Missing on Android** | Support cannot request structured diagnostics on Android. |

---

### 4.6 Communities & Spaces Subsystem

| Feature / Screen | iOS (`CommunitiesHomeView.swift` + Subviews) | Android (`CommunitiesHomeView.kt` + Subviews) | Parity Status | Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Tab 1: Joined Communities** | Lists user's communities with badge, unread count, and host indicator. Pull-to-refresh. | Lists user's communities with pull-to-refresh. | ✅ **Match** | Both fetch from `/communities/mine`. |
| **Community Discovery** | **Dedicated `CommunityDiscoverSheet.swift`**: Trending communities load instantly before typing; searching queries `/communities/search` with debounce. | Search box is inline on top of the list; sets `discovering = true` and replaces the joined list in place. | ⚠️ **Architecture Gap** | iOS has a clean dedicated modal browse sheet; Android forces state toggles in the root view. |
| **Community Spaces List** | Group channels categorized into text spaces, voice lounges, and tournament threads. | Group channels categorized into spaces. | ✅ **Match** | Both display spaces. |
| **Community Host Inbox** | `CommunityInboxView.swift`: Dedicated request inbox for join applications with accept/reject. | `CommunityHostInboxView.kt`: Port of inbox view. | ✅ **Match** | Both support inbound request approvals. |
| **Admin Control Panel** | `CommunityAdminPanel.swift`: Full admin controls for roles, bans, permissions, and settings. | `CommunitySettingsScreen.kt` + `EventManagementScreens.kt`. | ⚠️ **UX Flow Gap** | Android split admin into multiple partial screens instead of the unified iOS admin panel. |

---

### 4.7 Map & Live Location Subsystem

| Screen / Feature | iOS Implementation | Android Implementation | Parity Status | Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Map Tab Availability** | Feature B in testing; hidden from `Tab.shipped` on both platforms. | Hidden from `Tab.shipped`. | ✅ **Match** | Both platforms hold Map behind feature flag. |
| **Map Onboarding Flow** | **Full 4-Screen Carousel**: `MapOnboardingFlow.swift`<br>1. `MapIntroScreen.swift`<br>2. `MapPrivacyScreen.swift`<br>3. `MapMoveScreen.swift` | **Completely absent**. Android has no map onboarding flow. | ❌ **Missing on Android** | When Map is enabled, Android has no introduction, privacy consent, or motion tutorial. |
| **Map Live Movement Broadcast** | `MapStartMoveSheet.swift`: Choose destination, transportation mode, ETA, and audience. | **Completely absent**. Only audience sheet exists. | ❌ **Missing on Android** | Android cannot broadcast a live move or trip ETA to friends. |
| **Map Settings & Controls** | `MapSettingsView.swift` & `MapNotificationsView.swift`: Satellite toggle, ghost duration picker, geofence radius. | Inline controls in `MapTabView.kt`. | ⚠️ **Architecture Gap** | iOS has dedicated sheet views; Android is monolithic. |

---

### 4.8 Games Subsystem

| Feature / UI | iOS (`GamesHomeView.swift`) | Android (`GamesHomeScreen.kt`) | Parity Status | Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Catalog Carousel** | Large featured game artwork cards at top, categorized grids below (`Board`, `Arcade`). | Large featured cards, categorized sections below. | ✅ **Match** | Visual layout is aligned. |
| **Setup Sheet** | `GameEntryFlow.swift`: Choose opponent (Friend vs Bot), select difficulty or over count. | `setupGame` dialog with friend/bot picker. | ✅ **Match** | Logic and options match. |
| **Coin Toss / Match Start** | **SceneKit 3D Coin Scene** (`CoinSceneView.swift`): Realistic 3D metallic coin flipping with physical shadows and haptics. | 2D Canvas rotate/flip animation. | ⚠️ **Visual Fidelity Gap** | iOS uses a true 3D metal shader; Android uses a flat 2D sprite rotation. |
| **Lobby Screen** | `GameLobbyView.swift`: Waiting for opponent with animated pulse, match code, and cancel button. | `LobbyScreen.kt`: Waiting room with opponent status. | ✅ **Match** | Both handle matchmaking lifecycle. |

---

### 4.9 AI Assistant Hub

| Component | iOS (`Main/AI/`) | Android (`AIChatView.kt`) | Parity Status | Detail |
| :--- | :--- | :--- | :--- | :--- |
| **Status in Navigation** | Excluded from `Tab.shipped` (hidden from bar). | Excluded from `Tab.shipped` (hidden from bar). | ✅ **Match** | Both correctly hide unreleased AI tab. |
| **Implementation Depth** | Full multi-file subsystem: `AIHubView.swift`, `AIChatView.swift`, `AIModels.swift`, SQLite GRDB storage (`AIStore.swift`). | Single 170-line dummy view (`AIChatView.kt`) with hardcoded mock responses and delays. | ❌ **Backend & Persistence Gap** | iOS has a complete local AI message database schema; Android is a temporary mock. |

---

## 5. Comprehensive Action Items: Bringing Android to 100% iOS Parity

To bring Android to complete parity with the deep iOS update, execute the following 5 phases:

### Phase 1: Foundation & Continuous Geometry
1. **Create `SquircleShape`**: Implement continuous cubic bezier curvature in Compose so Android cards, buttons, and bubbles eliminate sharp circular fillets.
2. **Implement `Modifier.voiidGlass()`**: Add the specular highlight brush, translucent surface card tint, and `RenderEffect` blur (with API 31+ window `FLAG_BLUR_BEHIND` support).
3. **Harmonize Brand Colors**: Fix `VoiidPalette.PrimaryDark` so filled primary buttons do not lift to low-contrast `#78AAAD` on dark grounds; maintain `#13828C` Tide with white text.

### Phase 2: Navigation Shell & Tab Bar
1. **Apply Glass to `TabBar`**: Replace the static `0.86f` background in `RootTabView.kt` with `Modifier.voiidGlass()`.
2. **Implement Elastic Distance Physics**: Update indicator stretch from direction-based to travel-distance-based (`min(1.25 + distance * 0.28, 2.2)`).
3. **Add Full-Screen Tab Swipe**: Wire `HorizontalPager` or gesture drag detection so users can swipe seamlessly between main tabs.

### Phase 3: Settings & Profile Architecture Alignment
1. **Remove Inline Root Editing**: Delete the inline `BasicTextField` editors for Name, Bio, and Username from `SettingsScreen.kt`. Restore the clean identity row that navigates to `EditProfileScreen`.
2. **Relocate "Delete my account"**: Remove the danger card from the root of `SettingsScreen.kt`. Place it at the bottom of `EditProfileScreen.kt` in a dedicated "Danger zone" section.
3. **Upgrade `EditProfileScreen.kt`**:
   - Add photo picker sheet ("Take Photo", "Choose from Library", "Cancel").
   - Enable live debounced username availability checking with `"Available"` (teal) and `"Taken"` (red) badges.
   - Add the 140-character bio counter.
4. **Add Diagnostics to Help & Support**: Add the `"Diagnostics"` section with system share intent to `HelpAndSupportScreen.kt`.

### Phase 4: Message Context Actions & Media Viewer
1. **Upgrade Message Long-Press**: Replace standard `DropdownMenu` with a custom floating popover featuring 3D elevation, background scrim blur, and the horizontal bouncy emoji reaction pill.
2. **Build Multi-Photo `ChatMediaViewer`**:
   - Implement horizontal `HorizontalPager` for conversation media.
   - Add pinch-to-zoom and swipe-down-to-dismiss gesture.
   - Add the bottom chronological thumbnail filmstrip with cell reuse.
   - Add "Jump to message" action.

### Phase 5: Missing Feature Ports
1. **Map Onboarding**: Port `MapIntroScreen`, `MapPrivacyScreen`, `MapMoveScreen`, and `MapOnboardingFlow` to `apps/android/app/src/main/java/com/voiid/app/main/map/`.
2. **Community Discovery Sheet**: Extract inline community search into a dedicated modal `CommunityDiscoverSheet.kt` featuring trending communities.
3. **Empty State Button**: Add the `"New group"` button to the Android groups empty state. Add "Open Note to Self" to direct chats empty state.

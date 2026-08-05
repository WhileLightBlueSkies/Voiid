# 06 — Reels (Clips) profile page & feed: modern UI treatment

Scope: `CreatorProfileView`, `ClipsFeedView`, `MyClipsView` and the fullscreen player chrome, on
both platforms. **Hard constraints honoured throughout:** the square-cornered 3-column, 2pt/2dp,
9:16 grid stays exactly as it is (the founder reverted a grid change before — tile shape and
geometry are not touched by anything below), and the pager performance work (player pool with the
asymmetric ±window, playback-URL TTL cache, thumbnail cache) is kept untouched and is explicitly
listed as "do not regress" for every fix.

---

## 1. What exists today (cited)

### 1.1 Design tokens (the vocabulary every spec below uses)

- **iOS** — `apps/ios/Voiid/Voiid/DesignSystem/Theme.swift`
  - `VoiidColor` (NOCTURNE, dark-first): `primary` aubergine `dyn(0x2E2440, 0xB59BE0)` (Theme.swift:48),
    `background` `dyn(0xF1EEF5, 0x0D0B14)` (:50), `surfaceCard` `dyn(0xFFFFFF, 0x1C1826)` (:52),
    `textPrimary` (:69), `textSecondary` (:70), `textOnPrimary` (:72), `divider` (:78),
    `fieldBorder` (:79), `fieldFill` (:81), `accent` amber `dyn(0xB57210, 0xE8A33D)` (:91),
    `error` (:119).
  - `VoiidSpacing` xs 4 / sm 8 / md 16 / lg 24 / xl 32 / xxl 48 (Theme.swift:130-137).
  - `VoiidRadius` sm 8 / md 12 / lg 16 / pill 999 (Theme.swift:141-146).
  - `VoiidFont.rounded(size, weight)` = SF Pro Rounded; scale display 34b / title 22sb / headline 17sb /
    body 17 / callout 16 / subhead 15 / footnote 13 / caption 12 (Theme.swift:153-166).
- **Android** — mirrors value-for-value:
  - `VoiidColor`/`VoiidPalette` in `ui/theme/Color.kt` (PrimaryDark `0xFFB59BE0` Color.kt:135,
    BackgroundDark `0xFF0D0B14` :137, SparkDark amber `0xFFE8A33D` :175, FieldFill :168-169, etc.).
  - `VoiidSpacing`/`VoiidRadius` in `ui/theme/Dimens.kt:6-21`.
  - `VoiidFont.rounded(size, weight)` = Nunito variable; same scale (`ui/theme/Type.kt:43-60`).
- Shared interaction primitives: iOS `SoftPressStyle` scale 0.96 + dim + soft haptic
  (`DesignSystem/Components.swift:85-96`) and `VoiidPrimaryButton` 64pt radius-lg pill
  (Components.swift:100-118); Android `Modifier.softClickable` (`ui/components/Components.kt:67-90`)
  and `VoiidPrimaryButton` (Components.kt:109-129).

### 1.2 Feed (Explore/Following grid)

- **iOS `Main/Clips/ClipsFeedView.swift`**
  - Header row: `Text("Clips")` in `VoiidFont.display` + three trailing SF-symbol buttons — My clips
    (`person.crop.square.filled.and.at.rectangle`), my creator profile (`person.circle`, only when
    `creators.me` exists), compose (`plus.circle.fill` 28pt in `primary`) (ClipsFeedView.swift:349-393).
  - Scope control: a **stock UIKit segmented `Picker`** ("Explore"/"Following")
    (ClipsFeedView.swift:112-126).
  - Grid: `LazyVGrid` 3 flexible columns, `spacing: 2` (:34, :250), tile = `ClipThumbnail` +
    bottom scrim `LinearGradient(.clear → .black.opacity(0.55))` + `eye.fill` + compact count
    (:279-307); upload-progress and failed overlays on the tile itself (:309-345).
  - States: skeleton `ClipsGridSkeleton` (:236), error-beats-empty ordering (:228-241), Following
    empty state hand-rolled inline (`person.2` icon, :152-168).
  - Fullscreen opens via **`fullScreenCover(item:)`** at the tapped index (:55-58) — a plain modal
    slide-up, no visual connection to the tapped tile.
- **Android `main/clips/ClipsFeedView.kt`** — same structure; scope control is **custom pills**
  (`ScopePill`, filled `primary` when selected, `fieldFill` when not — ClipsFeedView.kt:330-346),
  header uses `Icons.Default.VideoLibrary`/`AccountCircle`/`AddCircle` (:115-140), tile
  `ClipTile` with the same scrim and overlays (:220-328), Following feed with its own grid and
  empty state (:353-449).

### 1.3 Creator profile

- **iOS `Main/Clips/CreatorProfileView.swift`**
  - Header: 84pt circular avatar (or `fieldFill` circle + initial) (CreatorProfileView.swift:152-169),
    three stats beside it (`rounded(17,.bold)` value over `caption` label, :171-181), display name +
    `checkmark.seal.fill` 13pt in `primary` for `is_verified` (:105-114), @handle, bio, link (URL-validated
    before it becomes tappable, :127-143), then a full-width 44pt rect (radius `md`) Follow/Following or
    Edit-profile button (:183-216).
  - Grid: same 3-col layout with the aspect-ratio-on-the-cell fix documented in the file (:230-268).
  - `CreatorEditSheet` for display name / bio / link (:289-366).
- **Android `main/clips/CreatorProfileView.kt`** — same header composition (avatar :164-183,
  stats :186-190, name + `Icons.Filled.Verified` 14dp :194-205, bio/link :210-216), Follow button
  only for non-self (:220-239), grid as `LazyVerticalGrid` with a spanning header item (:126-149),
  tile `CreatorClipTile` (:252-278).

### 1.4 My clips

- iOS `Main/Clips/MyClipsView.swift`: same grid, tile management via long-press `contextMenu`
  (Edit caption & cover / Delete, MyClipsView.swift:116-129), `ClipEditSheet` (:137-296).
- Android `main/clips/MyClipsView.kt`: `MyClipTile` with **always-visible** edit/delete
  `TileAction`s (MyClipsView.kt:188-215) and its own `ClipEditSheet` (:263+).

### 1.5 Fullscreen player chrome (the part of "feed chrome" users stare at)

- iOS `Main/Clips/ClipFullscreenView.swift`: vertical `ScrollView` pager with `.paging`
  (ClipFullscreenView.swift:81-112); **keep-list performance work**: asymmetric preload window
  `[index-1 … index+2]`, current page prepared first and alone, neighbours parallel + detached
  (:116-147), playback-URL TTL cache in `Networking/ClipsEngine.swift:265-296`, thumbnail
  `NSCache` + in-flight coalescing in `Main/Clips/ClipsUIKit.swift:42-77`.
  - Chrome: back chevron + speaker state icon top (:386-400), author avatar/name + caption
    (3-line limit) bottom-left, right rail heart/comment/eye actions (:403-435) — **all drawn as
    white text/icons directly on the video with no scrim** (the `chrome` VStack at :384-436 contains
    no gradient layer; only the *grid tiles* have scrims). Tap-anywhere toggles mute (:343-356);
    press-and-hold thirds for 0.5x/2x with a `speedPill` in `.ultraThinMaterial` (:326-341, :440-452).
- Shared kit `Main/Clips/ClipsUIKit.swift`: `ClipCount.compact` (truncating K/M/B, :15-36),
  `ClipShimmer` single 1.2s sweep (:127-148), `ClipVideoLoader` blurred-cover + branded ring
  (:154-200), `ClipsEmptyState` (noClips/noneFromYou/failed, :209-279), `ClipsGridSkeleton`
  (:282-294). Android port in `main/clips/ClipsUIKit.kt` (shimmer :62-85, thumbnail via Coil
  :92-131, loader :138-177, empty states :186-242, skeleton :246-258).

---

## 2. What is broken or weak (cited, with root cause)

### Functional defects found while auditing the UI

1. **Creator-profile grid tiles are dead on BOTH platforms.** iOS: the tile `ZStack` gets
   `.contentShape(Rectangle())` but is never wrapped in a `Button` and has no tap gesture
   (CreatorProfileView.swift:245-267 — compare the Explore grid, where each tile is a `Button`,
   ClipsFeedView.swift:252-262). Android: `CreatorClipTile` is a plain `Box` with no
   `softClickable`/`clickable` (CreatorProfileView.kt:252-278). Root cause: the profile grid was
   built by copying the tile *visuals* from the feed without the tap plumbing, and there is no
   pager that can play a creator's clip list (`ClipFullscreenView` indexes only into
   `engine.clips` — ClipFullscreenView.swift:39-41; the same limitation is already acknowledged
   for the Following feed at ClipsFeedView.swift:176-179). A profile is currently a gallery you
   can look at but never play — the single biggest "this feels broken/outdated" signal on the
   whole surface.
2. **Android has no way to edit your creator profile.** iOS shows "Edit profile" for `is_self`
   (CreatorProfileView.swift:187-200); Android renders the follow button only for `!p.is_self`
   and *nothing* for self (CreatorProfileView.kt:218-239 — the comment even says "Your own page
   shows nothing"), and no Android counterpart of `CreatorEditSheet` exists (the only
   `ClipEditSheet` in `main/clips/MyClipsView.kt:263` edits a clip, not the profile).
3. **Android profile link is dead text.** iOS validates and renders a tappable `Link`
   (CreatorProfileView.swift:127-143); Android prints `link_url` as a plain `Text` with no
   `UriHandler` (CreatorProfileView.kt:213-215).
4. **Fullscreen chrome has no contrast protection.** Caption, author name and the action rail are
   white-on-video with only a `.shadow` on grid tiles but nothing in the fullscreen `chrome`
   (ClipFullscreenView.swift:384-436). Over a bright clip the caption is illegible. (Signal
   solves exactly this with a "gradient protection" layer — §3.)

### Visual/dated-design weaknesses

5. **Scope control is inconsistent across platforms and stock-looking on iOS.** iOS uses the
   default `UISegmentedControl` styling (ClipsFeedView.swift:112-118) — the one control on the
   screen that visibly isn't Voiid — while Android already has branded pills
   (ClipsFeedView.kt:330-346). Root cause: iOS predates the Android port's pills.
6. **Profile header is a flat stack with no focal treatment**: bare 84pt circle (no ring, no
   elevation), 13pt verified glyph in the same `primary` used by every button so it doesn't read
   as a *badge* (CreatorProfileView.swift:109-113, CreatorProfileView.kt:200-204), a full-width
   sharp-ish (radius 12) Follow rectangle rather than the pill language the rest of the app's
   empty-states/CTAs use (`ClipsEmptyState` uses a `Capsule`, ClipsUIKit.swift:244), and no
   follow-state animation — the label just swaps.
7. **No transition between grid and player.** `fullScreenCover` (iOS, ClipsFeedView.swift:55-58)
   and whatever navigation Android's `onOpenClip` performs present the player as an unrelated
   modal; the tapped thumbnail doesn't expand into the video, and dismissing doesn't return to
   the tile. Every mainstream reels surface does a shared-element zoom here (§3).
8. **Empty states are static.** A dimmed SF symbol + two lines (ClipsUIKit.swift:219-251,
   ClipsUIKit.kt:206-241). Serviceable, but the Following empty state on iOS doesn't even use the
   shared `ClipsEmptyState` component — it's re-hand-rolled inline with no CTA
   (ClipsFeedView.swift:152-168), so the two platforms and two scopes all drift slightly.
9. **Header row is icon soup.** Three glyph buttons of different visual families
   (`person.crop.square.filled.and.at.rectangle` is unrecognisable at a glance;
   ClipsFeedView.swift:355-390). Your own creator identity — the thing Instagram anchors with
   your avatar — is a generic `person.circle`.
10. **Dark-theme nits.** Grid gutters are `background` showing through — correct in dark
    (`0x0D0B14` reads as black chrome around video) but in *light* theme the lavender-white
    `0xF1EEF5` gutters around video tiles look washed; the tile scrims/counts are fine (fixed
    black scrim is correct on video). The upload/failed overlays use raw
    `Color.black.opacity(…)` consistent with scrims — fine — but the failed overlay's tap
    targets are 10pt text buttons (ClipsFeedView.swift:335-342), below the 44pt minimum.

*(Checked for the known bug classes: this surface's models are all display-side here; no
encodeDefaults / keyNotFound / NULL-upsert issues arise in these three views. The
error-beats-empty ordering is already correct everywhere — ClipsFeedView.swift:228-241,
MyClipsView.swift:62-77, CreatorProfileView.kt:112-119.)*

---

## 3. How Instagram (pattern reference) + Signal (source reference) do it

**Instagram profile (current layout, descriptive):**
- Avatar ~88pt top-left **with a ring treatment** (gradient ring when a story is live, hairline
  otherwise); stats row (posts/followers/following) fills the space to its right — same skeleton
  Voiid already has, so modernisation is *treatment*, not *restructure*.
- Name line, category, bio, link row *under* the avatar block; a **row of buttons** — primary
  filled "Follow" that flips to a neutral "Following ⌄" chip; buttons are ~36pt, radius ~8-10,
  side-by-side rather than one full-width slab.
- Verified is a distinctly-coloured seal immediately after the name at name-size, not button-blue.
- Content area is a **grid of 9:16 tiles with a view-count bottom-left** — exactly Voiid's grid.
- Tapping a tile performs a **shared-element zoom**: the thumbnail expands into the player;
  swipe-down shrinks it back to its cell.
- Reels feed chrome: bottom-left column = avatar + handle + inline Follow chip + expandable
  caption + audio marquee; right rail = like/comment/share stacked with counts; **both sit on a
  bottom gradient scrim**, and chrome auto-hides on long-press.

**Signal (actual source, flow patterns only):**
- *Scrim behind chrome:* Signal-iOS stories place a dedicated `gradientProtectionView` behind
  the bottom content — height = 40% of the view when a caption is present, colors
  `[.clear, .black.withAlphaComponent(0.8)]`
  (`Signal stack/Signal-iOS/Signal/src/ViewControllers/HomeView/Stories/Context View/StoryItemMediaView.swift:839-847`),
  constrained edge-to-edge at the bottom (:67-82).
- *Chrome fades with playback state:* pausing with `hideChrome` animates `bottomContentVStack`
  **and the gradient** to alpha 0 in 0.15s ease-in-out, and play restores both together
  (StoryItemMediaView.swift:208-234) — the scrim is treated as part of the chrome, never a
  permanent darkening of the media.

Both references agree with the constraints: nobody changes the grid; everything modern lives in
the header treatment, the chrome, and the transitions.

---

## 4. Recommended fixes (ordered)

Every item preserves: 3-column / 2-gutter / 9:16 square-cornered tiles; `ClipPlayerPool` +
asymmetric preload window (ClipFullscreenView.swift:116-147); `playbackURL` TTL cache
(ClipsEngine.swift:265-296); `ClipThumbCache` (ClipsUIKit.swift:42-73) / Coil caching.

### F1 — Make creator-profile grid tiles playable (HIGH, both platforms)
The profile grid must open a pager over **that creator's** clip list.
- Generalise the fullscreen pager to take an injected clip list + paging closure instead of
  reading `engine.clips` directly: iOS `ClipFullscreenView` (`Main/Clips/ClipFullscreenView.swift`)
  gains an init over `[Clip]`-shaped rows (map `CreatorService.CreatorClipRow` → the pager's
  row type) with `loadMore` delegating to `creators.loadMoreClipsIfNeeded`; the player pool,
  preload window, and URL cache code paths are reused unchanged (`playbackURL(for:)` only needs a
  clip id). Android same for `ClipFullscreenView.kt` + `CreatorStore`.
- Wrap the iOS tile in `Button { openIndex = idx } .buttonStyle(.plain)`
  (CreatorProfileView.swift:245-267) and present with `fullScreenCover` exactly like
  ClipsFeedView.swift:55-58. Android: add `.softClickable` to `CreatorClipTile`
  (CreatorProfileView.kt:253) and route through a new nav destination.
- This also unlocks fixing the Following-feed workaround (tiles currently open the *creator*
  instead of the clip — ClipsFeedView.swift:176-179, ClipsFeedView.kt:399-407).
- Risk: medium — touches the pager's data source; mitigate by keeping `ClipsEngine`-backed
  explore path as-is and adding the injected-list path alongside.

### F2 — Modern profile header treatment (HIGH, both platforms, pure UI)
Component spec (tokens only, no new colors):
- **Avatar**: 96pt/96dp circle; ring = 2.5pt `Circle().strokeBorder` in
  `LinearGradient(colors: [VoiidColor.primary, VoiidColor.accent], startPoint: .topLeading, endPoint: .bottomTrailing)`
  with a 3pt `VoiidColor.background` gap between ring and image (Instagram story-ring language,
  used here as static brand treatment). Fallback initial stays `fieldFill` + `rounded(34,.semibold)`.
- **Stats row**: keep position (beside avatar — the above-the-fold rationale at
  CreatorProfileView.swift:94-95 stands); value `rounded(20,.bold)` `textPrimary`, label
  `caption` `textSecondary`, separated by 1pt × 24pt `VoiidColor.divider` hairlines; each stat
  gets `SoftPressStyle`/`softClickable` (future: follower list) — even inert, the press affordance
  modernises the row.
- **Verified badge**: move off `primary` (which is "every button") to a dedicated mini-component
  `VerifiedSeal`: `checkmark.seal.fill` / `Icons.Filled.Verified` at 16pt in `VoiidColor.accent`
  (amber = the "rare, must-be-seen" token per Theme.swift:88-91) with
  `.symbolRenderingMode(.hierarchical)` on iOS. One shared component per platform so the profile
  header, fullscreen chrome, and future comment rows can't drift.
- **CTA row**: replace the full-width 44pt rectangle (CreatorProfileView.swift:201-215 /
  CreatorProfileView.kt:220-239) with a two-up row, 40pt tall, radius `VoiidRadius.md`,
  `continuous` corners: **Follow** filled `primary`/`textOnPrimary` flipping to `fieldFill` +
  1pt `fieldBorder` stroke + `textPrimary` "Following"; state change animated with
  `withAnimation(.spring(response: 0.3, dampingFraction: 0.7))` + `Haptics.success()` on
  follow. Second slot: self → "Edit profile" (`fieldFill`), other → "Share profile"
  (`fieldFill`; share sheet with the handle URL). No Message button, ever — preserves the
  reachability rule documented at CreatorProfileView.swift:12-16.
- **Bio**: 3-line clamp + "more" expander (`textSecondary`), matching Instagram; link row
  prefixed with `link` SF symbol / `Icons.Default.Link` at 13pt.
- Files: `apps/ios/Voiid/Voiid/Main/Clips/CreatorProfileView.swift`,
  `apps/android/.../main/clips/CreatorProfileView.kt`. Risk: low — header-only; the grid item
  span/aspect fix comments (CreatorProfileView.swift:232-244) must be left intact.

### F3 — Android parity: Edit profile + tappable link (MEDIUM, Android)
- Port `CreatorEditSheet` (iOS CreatorProfileView.swift:289-366) into
  `main/clips/CreatorProfileView.kt` (ModalBottomSheet with display name / bio / link fields,
  save via the same `CreatorStore` update path; do NOT send the handle — mirror the iOS
  rationale at :349-355). Show "Edit profile" for `is_self` per F2's CTA row.
- Make `link_url` tappable via `LocalUriHandler` only when `android.net.Uri.parse(it).scheme != null`,
  mirroring iOS's parse-before-Link guard (CreatorProfileView.swift:129-142).
- Files: `CreatorProfileView.kt`, `model/CreatorStore.kt` (if an update call is missing),
  `net/CreatorService.kt`. Risk: low.

### F4 — Unified branded scope pills + feed header cleanup (MEDIUM, both)
- iOS: replace the stock segmented `Picker` (ClipsFeedView.swift:112-118) with the pill pair
  Android already ships (ClipsFeedView.kt:330-346): capsule (`VoiidRadius.pill`), selected =
  `primary` fill + `textOnPrimary`, unselected = `fieldFill` + `textSecondary`,
  `rounded(14,.semibold)`, `SoftPressStyle(scale: 0.96)`, with a `matchedGeometryEffect`
  sliding the filled capsule between the two labels.
- Header: replace `person.circle` with the user's actual creator avatar in a 28pt circle
  (reuse `ClipThumbnail` + `creators.me.avatar_url`, initial fallback) — identity anchor à la
  Instagram; swap `person.crop.square.filled.and.at.rectangle` for `square.grid.3x3` /
  keep `VideoLibrary` on Android but align both to the same two-icon + avatar arrangement.
- Files: `ClipsFeedView.swift`, `ClipsFeedView.kt`. Risk: low.

### F5 — Fullscreen chrome: scrim protection + polish (MEDIUM, both)
- Add Signal-style gradient protection behind the bottom chrome: iOS insert
  `LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)`
  as the bottom ~40% of the `chrome` ZStack (ClipFullscreenView.swift:384-436), plus a shallow
  top gradient (`.black.opacity(0.35) → .clear`, ~120pt) behind the back/mute row; fade the
  scrim **with** the chrome exactly as Signal does on pause/hide
  (StoryItemMediaView.swift:208-234 pattern). Android mirror in `ClipFullscreenView.kt`'s
  chrome overlay.
- Right rail: 44pt hit targets, count labels `rounded(12,.semibold)`; like button gets a
  spring pop (`scaleEffect` 1→1.3→1 on like, iOS `.symbolEffect(.bounce)` where available) —
  the heart/`error`-red state already exists (ClipFullscreenView.swift:423-427).
- Author row: add an inline **Follow chip** (capsule, 1pt white-stroke, `rounded(12,.semibold)`)
  after the author name when not following — wire to the same `toggleFollow`; hides when
  following (Instagram pattern). Requires author handle on the clip row (already present for
  following rows: `author_handle`, ClipsFeedView.swift:179).
- Risk: low-medium; do not touch the pager/preload code (:116-147).

### F6 — Grid→player zoom transition (MEDIUM, both, progressive enhancement)
- iOS: adopt the iOS 18 zoom transition — `.navigationTransition(.zoom(sourceID:in:))` with
  `.matchedTransitionSource` on the tapped tile — for `ClipFullscreenView` presentation
  (`ClipsFeedView.swift:55-58` and the F1 profile presentation); fall back to the current
  `fullScreenCover` below iOS 18 (availability-gated).
- Android: wrap feed grid + player route in `SharedTransitionLayout` (Compose 1.7+) with
  `sharedElement` on the thumbnail; fall back to default nav animation otherwise.
- Risk: medium (transition APIs interact with `LazyVGrid`/`LazyVerticalGrid` recycling); ship
  behind availability checks, never block F1.

### F7 — Empty-state and skeleton polish (LOW, both)
- Extend `ClipsEmptyState` (ClipsUIKit.swift:209-279, ClipsUIKit.kt:186-242) with a
  `followingNobody` kind and route the iOS inline Following empty state
  (ClipsFeedView.swift:152-168) through it, so all four states share one component. CTA:
  "Explore creators" switching scope back to Explore.
- Treatment: icon sits in a 72pt `fieldFill` circle with the icon in `primary`; iOS adds
  `.symbolEffect(.pulse)` (iOS 17+); title `title` (22sb) instead of `headline`; CTA stays the
  existing capsule (ClipsUIKit.swift:234-247). Android: same geometry, `infiniteRepeatable`
  alpha pulse 0.7→1.
- Skeletons already match final geometry (ClipsUIKit.swift:282-294 / ClipsUIKit.kt:246-258) — keep;
  add a 250ms staggered fade-in on first page landing (iOS `.transition(.opacity)` +
  per-index delay; Android `animateItem()`).
- Risk: trivial.

### F8 — Failed-upload overlay tap targets + light-theme gutter nit (LOW)
- Give Retry/Dismiss on the failed tile ≥44pt frames (currently 10pt text —
  ClipsFeedView.swift:335-342, ClipsFeedView.kt:292-307): Retry becomes a small capsule
  (`fieldFill` on the dark overlay, `rounded(12,.semibold)` white).
- Optional: in *light* theme only, render grid gutters and the area behind tiles in
  `VoiidColor.surfaceCard`-adjacent near-black? **No** — keep gutters `background` (changing
  gutter color changes the grid's look, which is off-limits in spirit); instead do nothing.
  Listed here explicitly so a repair agent doesn't "fix" it.

---

*Everything above is component-level and token-bound; no new hex values, no grid-geometry
changes, and no E2EE-adjacent surface is touched (Clips is a deliberate non-E2EE surface; the
no-Message rule on profiles is preserved by F2).*

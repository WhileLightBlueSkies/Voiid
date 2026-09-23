# `@voiid/web` — the marketing site

A static brochure. Next.js App Router, TypeScript, CSS Modules, `output: 'export'`.
No server state, no auth, no analytics, no form that collects anything, no external
asset of any kind. `npm run build -w @voiid/web` writes a plain directory of HTML to
`apps/web/out/`.

```
npm run dev  -w @voiid/web     # localhost:3000
npm run build -w @voiid/web    # static export → apps/web/out
npm run typecheck -w @voiid/web
npm run test:e2e -w @voiid/web # Playwright marketing-site checks
```

---

## The three rules

**1. Never write a raw hex.** Every colour is a custom property in `app/globals.css`,
copied from `apps/ios/Voiid/Voiid/DesignSystem/Theme.swift`. If you need a colour that
is not there, the token is missing: add it to `globals.css` in *both* themes and say
what it is for. Do not "improve" an existing value — fix `Theme.swift` and copy it
down, or the site and the product drift.

The only sanctioned exceptions are the four below, each commented where it occurs.
Three of them are not colour choices at all, which is the test to apply if you think
you have found a fifth:

- the browser-chrome colours in `app/layout.tsx`, `components/ThemeScript.tsx`, and
  `components/ThemeToggle.tsx` — they run before stylesheets or update the browser's
  `<meta name="theme-color">`, where `var()` is unavailable;
- the phone's Dynamic-Island cutout in `PhoneMockup.module.css` — a hole in the
  display, the same near-black in both themes because physics has no light mode;
- the `#000` stops in the Hero's `mask-image` — a mask samples *alpha*, so that is an
  opacity keyword wearing a colour's clothes;
- the `#ffffff` operand in the accent button's hover `color-mix()` — a lightening
  *operation* applied to `var(--color-accent)`, not a second colour.

**2. Never overclaim.** This is a privacy product, so a wrong sentence here is a
liability rather than a pitch. Before you write a claim, check it:

| Surface | Reality | Source |
|---|---|---|
| Messages, 1:1 and group | End-to-end encrypted | `006_messages.sql`, `013_message_ciphertexts.sql`, `011_mls.sql` |
| Voice + video calls, incl. group | E2EE media; the *log* (who, when, how long) is ours | `014_calls.sql` |
| Location shares, live location | E2EE | `018_location_shares.sql` |
| Moments / stories | E2EE to a known audience | `017_stories.sql` |
| **Clips, captions, thumbnails** | **Plaintext. The server reads them.** | `022_clips.sql` header |
| **Creator profiles, follows, likes, comments** | **Server-readable** | `022_clips.sql`, `029_creator_profiles.sql` |
| **Game moves, scores, results** | **Server-readable — it is the referee** | `024_games.sql` header |
| Games catalogue | Exactly four: Tic Tac Toe, Rock Paper Scissors, Snake, Hand Cricket | `024`, `025`, `026_games_snake` |
| Communities | **Does not ship. Do not build the page** — see the note below. | `RootTabView` (both platforms) |
| Payments | **Does not exist.** There is a `payments` domain *hue*, not a feature. | — |
| App Store / Play links | **None exist.** Do not invent one. | — |

If you are unsure whether something ships, grep before you write the sentence. Reach
for `<E2EEBadge>` and `<Callout>` — they exist so the honest sentence has somewhere
designed to live.

**A warning about Communities specifically**, because a grep makes it look shipped and
it is not. You will find `database/migrations/030_communities.sql`, a backend route
(`backend/api/src/routes/communityHostThreads.ts`) and an Android networking layer
(`net/CommunityService.kt`, `net/CommunityLink.kt`). None of that is reachable by a
user: **there is no Communities UI on either platform.** Both clients route the tab to
a placeholder — `apps/ios/Voiid/Voiid/Main/ComingSoonView.swift` via `RootTabView.swift`,
and `main/ComingSoonView.kt` on Android. Back end without a front end is not a feature,
so the site does not mention Communities at all — it is absent from `lib/nav.ts` by
design. (Note also that the `ComingSoonView` header comment names *Games* alongside
Communities; that comment is stale. Games is fully built on both platforms — iOS routes
`.games` to a real `GamesHomeView()` — so the Games claims on this site are sound.)

**3. Keep warm colour rare.** Teal is the brand accent. Amber belongs to games and
server-refereed states, where it carries meaning; avoid scattering it through generic
buttons or decoration. On the home page that warm moment is the Games card.

---

## Tokens (`app/globals.css`)

`:root` carries the light values and is the deliberate first-visit default.
`html[data-theme='dark']` redefines the same names after a visitor explicitly chooses
dark mode. The selection is stored as `voiid-theme`; it does not silently follow the
operating-system theme.

### Colour

| Token | Light | Dark | Use |
|---|---|---|---|
| `--color-primary` | `#13828c` | `#79ded0` | Brand and primary actions |
| `--color-primary-ink` | `#0b5c64` | `#8ce6d8` | Accessible brand-colour text |
| `--color-background` | `#fbfcfc` | `#07110f` | Page ground |
| `--color-surface` | `#ffffff` | `#0e1d1a` | Raised cards and panels |
| `--color-surface-2` | `#f2f5f6` | `#142824` | Inset wells and quiet chips |
| `--color-text` | `#0d1416` | `#f2faf8` | Primary copy |
| `--color-text-dim` | `#55646a` | `#a9c3bd` | Secondary copy |
| `--color-border` | `#dbe3e5` | `#26413c` | Card and control edges |
| `--color-accent` | `#13828c` | `#79ded0` | Brand accent |
| `--color-bubble-sent` | `#13828c` | `#5fcabb` | Phone previews only |
| `--color-bubble-received` | `#f2f5f6` | `#19322d` | Phone previews only |

Status colour is never the *only* signal — pair it with a glyph and a word, as
`E2EEBadge` does. Roughly one man in twelve has a colour-vision deficiency.

### Domain hues

Section identity only — never body text, never bubbles. Five come from the app; three
are site-side aliases so every nav entry has one.

| `DomainHue` | Light | Dark | Page |
|---|---|---|---|
| `chat` | `#0b5c64` | `#8ce6d8` | Messaging, Home |
| `calls` | `#146c3a` | `#83d8a6` | Calls |
| `map` | `#1e40af` | `#9ab9ff` | Map |
| `stories` / `clips` | `#6b21a8` | `#d6a8ef` | Clips |
| `payments` / `games` | `#8a5400` | `#f2bd72` | Games — the warm hue |
| `privacy` | `#0b5c64` | `#8ce6d8` | Privacy |

Apply a hue by passing `hue="map"` to `Hero`, `Section`, `FeatureCard`, `CTA`,
`PhoneMockup` or `Callout`. That sets `--hue` and `--hue-wash` on the subtree, and
every descendant reads `var(--hue)` — you never name the colour twice. For custom
markup inside a page, `hueVars('map')` from `lib/hues` returns the same style object.

### Type

`--font-sans` is `ui-rounded` first, so Apple platforms get SF Pro Rounded — the
product's own face — with no webfont and no render-blocking fetch. Sizes are fluid
`clamp()`; do not set a `font-size` in px.

`--text-display` · `--text-h1` · `--text-h2` · `--text-h3` · `--text-lede` ·
`--text-body` (17px, the app's) · `--text-small` (15) · `--text-caption` (13) ·
`--text-micro` (12)

Weights `--weight-regular|medium|semibold|bold|black` (black is the wordmark only).
Line heights `--leading-tight|snug|body|loose`. Tracking `--tracking-tight|normal|wide`.

### Spacing, radii, layout, motion

Spacing is the app's 4pt scale: `--space-3xs` 4 · `2xs` 8 · `xs` 12 · `sm` 16 ·
`md` 24 · `lg` 32 · `xl` 48 · `2xl` 64 · `3xl` 96 · `4xl` 128. `--section-gap` is the
fluid rhythm between page sections — `Section` applies it, so you should not.

Radii `--radius-sm` 8 · `md` 12 · `lg` 16 · `xl` 24 · `2xl` 32 · `pill`.

Layout `--container` 1120 · `--container-narrow` 720 (prose) · `--container-wide` 1320
· `--container-pad` (fluid) · `--header-height` 64.

Motion `--ease-out` · `--ease-in-out` · `--dur-fast` 120ms · `--dur-base` 240ms ·
`--dur-slow` 560ms. `prefers-reduced-motion` is collapsed globally in `globals.css`;
if a component has a *looping* animation, give it an explicit reduced-motion rule that
parks it in a readable still, the way `LockMotif` does.

### Global utility classes

`.container` · `.prose` (long-form copy: sets the measure and the rhythm, so a privacy
page can drop bare `<p>`/`<ul>` in) · `.eyebrow` · `.srOnly` · `.scrollX` (wrap any
wide table or diagram in this — nothing may scroll the page sideways) · `.noPrint`.

---

## Components

Import from `../components/<Name>`. Everything is a server component except
`SiteHeader`.

### `<Hero>` — `components/Hero.tsx`
Top of every page; carries the page's only `<h1>`. Draws its own gradient-mesh and
hairline-grid backdrop.

```ts
{ title: ReactNode; eyebrow?: string; lede?: ReactNode; actions?: ReactNode;
  aside?: ReactNode; note?: ReactNode; badges?: ReactNode; hue?: DomainHue;
  layout?: 'split' | 'center';   // inferred from `aside` if omitted
  reverse?: boolean; className?: string }
```

### `<Section>`, `<Grid>`, `<Split>` — `components/Section.tsx`
The page's rhythm and measure. Do not hand-roll a `<section>` + container + padding.

```ts
Section {
  children: ReactNode; id?: string; eyebrow?: string; title?: ReactNode;
  lede?: ReactNode; hue?: DomainHue;
  width?: 'narrow' | 'default' | 'wide' | 'full';   // default 'default'
  align?: 'start' | 'center';
  tone?: 'plain' | 'raised' | 'inset';
  headingLevel?: 2 | 3;                              // default 2
  flush?: 'top' | 'bottom' | 'both';
  as?: ElementType; className?: string; bodyClassName?: string
}

Grid  { children: ReactNode; columns?: 2 | 3 | 4; gap?: 'sm' | 'md' | 'lg'; className?: string }
Split { children: ReactNode; aside: ReactNode; reverse?: boolean;
        align?: 'center' | 'start'; className?: string }
```

`Grid` uses `auto-fit`/`minmax`, so a column can never be narrower than its content —
which is what causes sideways scroll on a phone. `Split`'s `reverse` changes the
*visual* order only; DOM and reading order stay copy-first.

### `<FeatureCard>`, `<StatLine>` — `components/FeatureCard.tsx`

```ts
FeatureCard {
  title: ReactNode; children: ReactNode; href?: string; hue?: DomainHue;
  glyph?: GlyphName; meta?: ReactNode;      // normally an <E2EEBadge>
  cta?: string;                             // only rendered with href
  span?: 1 | 2; headingLevel?: 2 | 3 | 4;   // default 3
  className?: string
}

StatLine { label: string; value: ReactNode; className?: string }
```

With `href` the whole card is clickable, but the anchor's accessible name is the title
alone — the body is not swallowed into it.

### `<CTA>` — `components/CTA.tsx`
The closing band. One per page.

```ts
{ title: ReactNode; lede?: ReactNode; actions?: ReactNode; note?: ReactNode;
  hue?: DomainHue; accent?: boolean; className?: string }
```

`accent` uses the brand accent treatment; warm amber remains reserved for games and
server-refereed status — see rule 3.

### `<Button>`, `<ButtonRow>` — `components/Button.tsx`
Every action is a link; there is deliberately no `<button>` variant.

```ts
Button {
  href: string; children: ReactNode;
  variant?: 'primary' | 'secondary' | 'ghost' | 'accent';   // default 'primary'
  size?: 'md' | 'lg'; arrow?: boolean;                       // default true for ghost
  icon?: ReactNode; external?: boolean; className?: string
}

ButtonRow { children: ReactNode; align?: 'start' | 'center'; className?: string }
```

### `<E2EEBadge>` — `components/E2EEBadge.tsx`
The honesty chip. Three states, and there must never be a fourth, softer one.

```ts
{ state?: 'e2ee' | 'public' | 'refereed';   // default 'e2ee'
  size?: 'sm' | 'md'; label?: string; detail?: string; className?: string }
```

- `e2ee` → "End-to-end encrypted" (green, lock)
- `public` → "Public — not encrypted" (neutral, broadcast) — *neutral, not red: this is
  a decision we stand behind, not a defect*
- `refereed` → "Server-refereed" (amber, controller) — **counts as the page's amber**

### `<Callout>` — `components/Callout.tsx`
Where the sentence about what we *cannot* do gets a frame of its own.

```ts
{ children: ReactNode; title?: ReactNode;
  tone?: 'honest' | 'note' | 'warn';   // default 'honest'
  glyph?: GlyphName; className?: string }
```

### `<PhoneFrame>` — `components/PhoneFrame.tsx`
**The** device. One silhouette for the whole site: the hero composition, every feature
page, and the interactive tour all render this, because a phone drawn three times is a
phone drawn three different shapes.

```ts
{ children: ReactNode;
  width?: string;                        // ANY CSS LENGTH — never a percentage, see below
  time?: string;                         // status-bar clock, default '9:41'
  chrome?: 'auto' | 'light' | 'dark';    // ink for the status bar + home indicator
  statusBar?: boolean;                   // off for a screen that draws its own
  label?: string;                        // makes it one labelled image; omit when interactive
  className?: string; screenClassName?: string; style?: CSSProperties }
```

Everything derives from `width` (the BODY width): bezel `0.042W`, body radius `0.17W`,
screen radius `0.128W` (concentric — body radius minus bezel), Dynamic Island 31.8% of
the screen at 3.4:1, home indicator 35.4%. The ratios come from a 6.1" iPhone.

Two rules that are easy to break:

- **`width` must be a real length.** It feeds `calc(var(--phone-w) * 0.042)` for the
  bezel and the radii; a percentage in there resolves against a different box and
  silently deforms the device. `min(23rem, 100cqw - 3rem, …)` is fine; `80%` is not.
- **The screen is a container** (`container-type: inline-size`), so everything drawn
  inside it is sized in `cqw`. That is why the same interface renders identically at
  13rem in the hero and 23rem in the tour, and why none of it needs a media query.

The frame is graphite in **both** themes. A real phone does not turn white when the
page does; only what is on the screen follows the theme.

### `<PhoneMockup>` + screen furniture — `components/PhoneMockup.tsx`
The *stage* around a `PhoneFrame`: hue bloom, tilt, the three size steps, and the
in-screen furniture below. It no longer draws a frame of its own. No screenshots: they
need a CDN and they go stale the day the app changes.

```ts
PhoneMockup {
  children: ReactNode; hue?: DomainHue;
  size?: 'sm' | 'md' | 'lg';            // 240 / 300 / 340px display, vw-capped
  tilt?: 'none' | 'left' | 'right';     // suppressed below 900px
  glow?: boolean;                        // default true
  label?: string;                        // describes the screen; required unless…
  decorative?: boolean;                  // …the surrounding copy already says it
  time?: string;                         // status-bar clock, default '9:41'
  className?: string
}

PhoneAppBar  { title: ReactNode; subtitle?: ReactNode; trailing?: ReactNode; back?: boolean }
ChatBubble   { children: ReactNode; side?: 'sent' | 'received'; meta?: string }
PhoneAvatar  { initials: string; size?: number; seed?: number }
PhoneRow     { avatar?: ReactNode; title: ReactNode; preview?: ReactNode;
               meta?: ReactNode; badge?: ReactNode }   // badge is amber — count it
```

Everything inside the screen is sized in `em` off the display width, so content scales
with `size` automatically. Content is clipped, not scrolled — compose it to fit.
`--screen-w` is the DISPLAY width; `PhoneFrame` takes the BODY width, which is
`--screen-w / 0.916`.

### The interactive tour — `components/AppSandbox/`
"Go through the app" opens a full-viewport simulation of the product. It is an
application, not a slideshow: tabs, one back stack per tab, a composer you can type in,
a call with a running clock, location sharing with an end time, a clip feed, and four
games that really play.

| File | Holds |
| --- | --- |
| `types.ts` | `TabId`, `Route`, `SandboxState`, `SandboxAction` |
| `state.ts` | the reducer — all navigation and every state change, pure |
| `data.ts` | chats, messages, moments, clips and the game catalogue |
| `screens.tsx` | one component per screen plus the nav bar |
| `games.tsx` | Tic Tac Toe, Rock Paper Scissors, Hand Cricket, Snake |
| `AppSandbox.tsx` | the dialog, the guide column, the phone |
| `app.module.css` | the interface inside the screen — all of it in `cqw` |

Rules it has to keep:

- **Navigation lives inside the phone.** The guide column on the left is a set of
  shortcuts; delete it and the app still works. That is the test that it is an app.
- **The tab bar belongs to tab roots only.** A pushed screen — a chat, a game, the
  settings list — takes the whole display, and whatever sits at its bottom absorbs the
  home-indicator gutter itself.
- **Clips is a tab root**, so it keeps the tab bar even though it is full-bleed. Hiding
  it there strands the visitor on the feed.
- **The game catalogue is exactly the four seeded games** (see `app/games/page.tsx`).
  A browser test asserts it.
- The whole thing is `import()`ed only after the button is pressed, and a test asserts
  the chunk is absent from the initial payload.

### `<LockMotif>` — `components/LockMotif.tsx`
The E2EE diagram: two devices, two keys, a sealed packet, and a server that only ever
sees the sealed thing. Authored SVG plus CSS.

```ts
{ size?: number; label?: string; idPrefix?: string; className?: string }
```

Set `idPrefix` if a page renders more than one, or the gradients cross-wire. The packet
rides a CSS `offset-path` rather than SMIL `animateMotion`, because SMIL ignores
`prefers-reduced-motion`; if you edit the path, edit it in both the TSX and the CSS.

### `<Glyph>` — `components/Glyph.tsx`
The icon set, drawn inline on a 24×24 grid, stroked at 1.6, always `currentColor`.

```ts
{ name: GlyphName; size?: number; title?: string; className?: string; style?: CSSProperties }
```

`GlyphName` = `chat` · `call` · `map` · `clips` · `games` · `privacy` · `lock` · `key` ·
`shield` · `eye-off` · `globe` · `group` · `device` · `note` · `sparkle` ·
`arrow-right` · `check` · `broadcast`

Omit `title` for decorative use (the default — it is then hidden from assistive tech).

### `<Wordmark>` — `components/Wordmark.tsx`

```ts
{ size?: number; muted?: boolean; className?: string }
```

### `<SiteHeader>` / `<SiteFooter>`
Rendered by `app/layout.tsx`. Pages never import them. The header's mobile menu is a
checkbox and a label, so it works without hydration; the footer carries the DPDP
grievance block.

---

## Adding a page

1. Add the route to `lib/nav.ts` — header, footer and the home grid all read from it.
   `blurb`, `hue` and `privacy` are used by all three.
2. `app/<route>/page.tsx`, exporting `metadata` (the layout appends "— Voiid").
3. `<Hero>` with the page's `hue`, then `<Section>`s, then one `<CTA>`.
4. Page-specific styling goes in `app/<route>/page.module.css`, using tokens only.
5. Check before you ship: one `<h1>`; headings descend without skipping; every
   `PhoneMockup` has a `label` or `decorative`; nothing scrolls sideways at 320px; at
   most one amber; every factual claim traceable to the table above.

## Contact details

`lib/contact.ts` holds the general, security and grievance-officer fields. **They are
all placeholders and the footer renders them visibly as placeholders** — dashed, italic,
"To be appointed". Do not fill them with plausible-looking text. A fabricated grievance
contact is worse than a blank one: someone writes to it, gets silence, and believes they
have exercised a right they have not. DPDP s.13 and IT Rules 2021 Rule 3(2) both require
a real named person with an Indian address. Flip `CONTACT_INCOMPLETE` when they are real.

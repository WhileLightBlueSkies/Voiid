# `@voiid/web` — the marketing site

A static brochure. Next.js App Router, TypeScript, CSS Modules, `output: 'export'`.
No server state, no auth, no analytics, no form that collects anything, no external
asset of any kind. `npm run build -w @voiid/web` writes a plain directory of HTML to
`apps/web/out/`.

```
npm run dev  -w @voiid/web     # localhost:3000
npm run build -w @voiid/web    # static export → apps/web/out
npm run typecheck -w @voiid/web
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

- the two `<meta name="theme-color">` values in `app/layout.tsx` — the browser chrome
  reads them before any stylesheet parses, so `var()` is not available;
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

**3. One amber moment per page.** Amber (`--color-accent`) is the single warm colour
in the system and its power is entirely its rarity. Count these as amber before you
add another: `<Button variant="accent">`, `<CTA accent>`, `<E2EEBadge state="refereed">`,
anything with `hue="games"` or `hue="payments"`, and the unread pill inside
`<PhoneRow badge>`. On the home page the amber moment is spent on the Games card.

---

## Tokens (`app/globals.css`)

`:root` carries the light values; `@media (prefers-color-scheme: dark)` redefines the
same names. Dark is the designed state — compose for it first, then check light.

### Colour

| Token | Light | Dark | Use |
|---|---|---|---|
| `--color-primary` | `#2E2440` | `#B59BE0` | Brand, every primary action |
| `--color-primary-soft` | `#6B5A8C` | `#8F78B8` | Primary at reading weight |
| `--color-background` | `#F1EEF5` | `#0D0B14` | The ground |
| `--color-surface` | `#FFFFFF` | `#1C1826` | Cards, one step up |
| `--color-surface-2` | `#EAE5F2` | `#171320` | Inset wells, inert chips |
| `--color-text` | `#241D33` | `#E6E1EF` | |
| `--color-text-dim` | `#5F5570` | `#A79CBD` | Body copy inside cards, captions |
| `--color-text-on-primary` | `#EFEAF7` | `#14101F` | On a filled primary surface |
| `--color-text-on-accent` | `#17120A` | `#241A08` | On a filled amber surface |
| `--color-divider` | `#E3DEEC` | `#241F2F` | Must recede |
| `--color-border` | `#D6CFE4` | `#342D42` | A line meant to be noticed |
| `--color-accent` | `#B57210` | `#E8A33D` | Amber. Once per page. |
| `--color-accent-quiet` | 12% amber | 14% amber | Amber wash |
| `--color-success` | `#1F7A52` | `#63C78D` | |
| `--color-error` | `#C0392F` | `#EF7A6B` | |
| `--color-warning` | `#B07818` | `#E0A83C` | |
| `--color-info` | `#2A5B8F` | `#7FB0E0` | |
| `--color-bubble-sent` | `#2E2440` | `#7862A6` | Inside `PhoneMockup` only |
| `--color-bubble-received` | `#FFFFFF` | `#1C1826` | Inside `PhoneMockup` only |
| `--color-text-on-bubble` | `#F8F5FC` | `#F8F5FC` | Fixed in both themes |

Status colour is never the *only* signal — pair it with a glyph and a word, as
`E2EEBadge` does. Roughly one man in twelve has a colour-vision deficiency.

### Domain hues

Section identity only — never body text, never bubbles. Five come from the app; three
are site-side aliases so every nav entry has one.

| `DomainHue` | Light | Dark | Page |
|---|---|---|---|
| `chat` | `#2E2440` | `#B59BE0` | Messaging, Home |
| `calls` | `#2E7D5B` | `#5FBE8D` | Calls |
| `map` | `#2A5B8F` | `#7FB0E0` | Map |
| `stories` / `clips` | `#7B4B8A` | `#C98BD8` | Clips |
| `payments` / `games` | `#A9690C` | `#E8A33D` | Games — **this is amber** |
| `privacy` | `#2E2440` | `#B59BE0` | Privacy |

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

`accent` is the amber treatment — see rule 3.

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

### `<PhoneMockup>` + screen furniture — `components/PhoneMockup.tsx`
A device drawn entirely in CSS — titanium rail, side buttons, Dynamic Island, home
indicator — that you fill with real markup. No screenshots: they need a CDN and they
go stale the day the app changes.

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

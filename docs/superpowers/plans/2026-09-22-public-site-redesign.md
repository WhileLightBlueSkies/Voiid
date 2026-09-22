# Voiid Public Website Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the public Voiid website as a fast, rounded, light/dark marketing experience with accurate SEO, an interactive full-screen app sandbox, and future-ready download links.

**Architecture:** Keep the existing static Next.js App Router application and make server components the default. Add only three focused client islands: theme selection, the existing mobile navigation behavior, and a dynamically imported app sandbox whose deterministic reducer owns all demo state. Shared configuration drives store availability, metadata, navigation, and sandbox destinations so missing links and future content changes are safe.

**Tech Stack:** Next.js 15, React 19, TypeScript 5.7, CSS Modules, inline SVG, Playwright 1.63, static export.

**Spec:** `docs/superpowers/specs/2026-09-22-public-site-redesign-design.md`

## Global Constraints

- Modify `apps/web` only; do not modify `apps/web-client`, iOS, Android, backend, or authenticated/client code.
- Light mode is the default first-visit experience; dark mode is explicitly selectable and persisted.
- Use rounded system fonts and rounded component geometry consistently; do not add a webfont download.
- Preserve verified privacy boundaries and do not advertise payments or unreachable features.
- Missing store links render as non-links labelled “Coming soon”; QR generation waits for a real destination.
- Keep `output: 'export'`; primary content and navigation must work without JavaScript.
- Do not add analytics, trackers, animation libraries, UI frameworks, or runtime external assets.
- Respect `prefers-reduced-motion`, visible focus, WCAG AA contrast, and 320px-wide layouts.

---

### Task 1: Browser Test Harness and Shared Marketing Configuration

**Files:**
- Modify: `apps/web/package.json`
- Modify: `package-lock.json`
- Create: `apps/web/playwright.config.ts`
- Create: `apps/web/e2e/marketing.spec.ts`
- Create: `apps/web/lib/site.ts`
- Create: `apps/web/lib/downloads.ts`
- Modify: `apps/web/app/layout.tsx`

**Interfaces:**
- Produces: `SITE_URL`, `SITE_NAME`, `SITE_DESCRIPTION`, and `absoluteUrl(path: string): string` from `lib/site.ts`.
- Produces: `STORE_LINKS: { appStore: string | null; playStore: string | null }` and `hasStoreLinks(): boolean` from `lib/downloads.ts`.
- Produces: a Playwright web server that runs `npm run dev -w @voiid/web` at `http://127.0.0.1:3000`.

- [ ] **Step 1: Add the Playwright test script and dependency**

Add to `apps/web/package.json`:

```json
{
  "scripts": {
    "test:e2e": "playwright test"
  },
  "devDependencies": {
    "@playwright/test": "^1.63.0"
  }
}
```

Run `npm install --package-lock-only` from the repository root so the workspace dependency is recorded without changing production dependencies.

- [ ] **Step 2: Create the browser test configuration**

Create `apps/web/playwright.config.ts` with Chromium, base URL `http://127.0.0.1:3000`, trace-on-first-retry, and the workspace development server command. Keep tests serial initially so the single static site server is deterministic.

- [ ] **Step 3: Write failing metadata and download-fallback tests**

Add tests that assert:

```ts
test('home exposes canonical metadata and software structured data', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveTitle(/private messaging.*Voiid/i);
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute('href', /^https:\/\//);
  await expect(page.locator('script[type="application\/ld\+json"]')).toContainText('SoftwareApplication');
});

test('missing store URLs never render broken links', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByText('Coming soon')).toHaveCount(2);
  await expect(page.locator('a[href="#"]')).toHaveCount(0);
});
```

- [ ] **Step 4: Run the tests and verify RED**

Run: `npm run test:e2e -w @voiid/web -- --grep "canonical metadata|missing store"`

Expected: FAIL because canonical metadata, software JSON-LD, and the download area do not exist.

- [ ] **Step 5: Implement shared site and download configuration**

Create `lib/site.ts` with one production URL fallback (`https://voiid.app`), a normalized `absoluteUrl`, and concise site description. Create `lib/downloads.ts` with both store URLs set to `null`. Update root metadata in `app/layout.tsx` with `metadataBase`, canonical defaults, richer Open Graph/Twitter fields, and organization/software JSON-LD rendered in the document body.

- [ ] **Step 6: Keep the download assertion intentionally red**

Run the focused test again. Expected: the metadata assertion passes while the download fallback remains red; Task 5 completes that behavior.

- [ ] **Step 7: Commit**

```bash
git add apps/web/package.json package-lock.json apps/web/playwright.config.ts apps/web/e2e/marketing.spec.ts apps/web/lib/site.ts apps/web/lib/downloads.ts apps/web/app/layout.tsx
git commit -m "test(web): add marketing browser coverage"
```

### Task 2: Dual-Theme Foundation and Rounded Site Chrome

**Files:**
- Create: `apps/web/components/ThemeScript.tsx`
- Create: `apps/web/components/ThemeToggle.tsx`
- Create: `apps/web/components/ThemeToggle.module.css`
- Modify: `apps/web/app/layout.tsx`
- Modify: `apps/web/app/globals.css`
- Modify: `apps/web/components/SiteHeader.tsx`
- Modify: `apps/web/components/SiteHeader.module.css`
- Modify: `apps/web/components/SiteFooter.tsx`
- Modify: `apps/web/components/SiteFooter.module.css`
- Modify: `apps/web/e2e/marketing.spec.ts`

**Interfaces:**
- Produces: `ThemeToggle` with accessible label `Switch to dark mode` or `Switch to light mode`.
- Persists explicit choice in `localStorage['voiid-theme']` as `light` or `dark`.
- Applies the active value to `document.documentElement.dataset.theme` before hydration.

- [ ] **Step 1: Write failing theme and mobile navigation tests**

Add Playwright tests that open `/`, assert light tokens initially, click the named theme toggle, assert `data-theme="dark"`, reload, and assert dark remains. Add a 375px viewport test that opens the menu, follows a feature link, and verifies the menu closes after navigation.

- [ ] **Step 2: Run the new tests and verify RED**

Run: `npm run test:e2e -w @voiid/web -- --grep "theme|mobile navigation"`

Expected: FAIL because the toggle and theme persistence do not exist.

- [ ] **Step 3: Implement the no-flash theme bootstrap**

`ThemeScript.tsx` returns an inline script that reads only `voiid-theme`, accepts only `dark`, and otherwise sets `light`. Keep light as the first-visit default even when the OS prefers dark. Place it in `<head>` before styles hydrate.

- [ ] **Step 4: Implement the theme toggle**

Build a 44px rounded switch with sun/moon glyphs, synchronized `aria-label`, and state read from `document.documentElement.dataset.theme`. On click, update the dataset, `localStorage`, and `meta[name="theme-color"]`.

- [ ] **Step 5: Rebuild global tokens for both approved directions**

Keep the existing semantic token names, define light values under `:root`, dark values under `html[data-theme='dark']`, and use `color-scheme` per theme. Preserve rounded system typography, fluid type, focus rings, spacing, and reduced-motion rules. Replace expensive broad blur with smaller pseudo-elements and opacity/transform motion.

- [ ] **Step 6: Rework header and footer chrome**

Keep the existing mobile disclosure logic, add `ThemeToggle`, simplify top-level labels, use a rounded floating header, and make the footer visually match both modes. Do not add store links yet.

- [ ] **Step 7: Run theme and navigation tests and verify GREEN**

Run: `npm run test:e2e -w @voiid/web -- --grep "theme|mobile navigation"`

Expected: PASS in Chromium.

- [ ] **Step 8: Commit**

```bash
git add apps/web/components/ThemeScript.tsx apps/web/components/ThemeToggle.tsx apps/web/components/ThemeToggle.module.css apps/web/app/layout.tsx apps/web/app/globals.css apps/web/components/SiteHeader.tsx apps/web/components/SiteHeader.module.css apps/web/components/SiteFooter.tsx apps/web/components/SiteFooter.module.css apps/web/e2e/marketing.spec.ts
git commit -m "feat(web): add rounded light and dark themes"
```

### Task 3: Homepage Hero and Encryption Story

**Files:**
- Create: `apps/web/components/HomeHero.tsx`
- Create: `apps/web/components/HomeHero.module.css`
- Create: `apps/web/components/DeviceScene.tsx`
- Create: `apps/web/components/DeviceScene.module.css`
- Create: `apps/web/components/EncryptionJourney.tsx`
- Create: `apps/web/components/EncryptionJourney.module.css`
- Modify: `apps/web/components/Button.tsx`
- Modify: `apps/web/components/Button.module.css`
- Modify: `apps/web/app/page.tsx`
- Modify: `apps/web/app/page.module.css`
- Modify: `apps/web/e2e/marketing.spec.ts`

**Interfaces:**
- `HomeHero({ onOpenTourId?: string })` renders the primary button with `data-open-app-tour` for client enhancement.
- `EncryptionJourney` renders a semantic three-step ordered list plus decorative animated SVG/CSS layers.
- `Button` gains an optional real-button rendering mode without changing existing link behavior.

- [ ] **Step 1: Write failing homepage content and reduced-motion tests**

Assert the new H1 contains the product positioning, the primary button is named `Go through the app`, the page contains one H1, the encryption section includes sender/ciphertext/recipient text in DOM order, and reduced-motion mode disables looping packet animation.

- [ ] **Step 2: Run focused homepage tests and verify RED**

Run: `npm run test:e2e -w @voiid/web -- --grep "homepage|encryption journey|reduced motion"`

Expected: FAIL because the new content and animation do not exist.

- [ ] **Step 3: Build the rounded product hero**

Create a server-rendered hero with the approved concise copy, two actions, a privacy proof line, and a responsive two-column layout. The primary action is a semantic button; without JavaScript its fallback anchor points to `#features`.

- [ ] **Step 4: Build the device composition**

Create two lightweight CSS/HTML device previews showing chat and call/map context. Use inline glyphs and semantic labels. Animate only transform and opacity; reduce perspective and shadows on narrow screens.

- [ ] **Step 5: Build the encryption journey**

Render three named stages: seal on sender, travel as ciphertext, open on intended device. Add a lock that changes from open to sealed, a travelling packet, and a verification check. Reduced motion displays the final sealed path without travel.

- [ ] **Step 6: Replace the homepage opening sections**

Use `HomeHero`, feature overview anchors, and `EncryptionJourney`. Remove old duplicated hero/tour framing while retaining accurate privacy copy arrays for later sections.

- [ ] **Step 7: Run focused tests and verify GREEN**

Run: `npm run test:e2e -w @voiid/web -- --grep "homepage|encryption journey|reduced motion"`

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/web/components/HomeHero.tsx apps/web/components/HomeHero.module.css apps/web/components/DeviceScene.tsx apps/web/components/DeviceScene.module.css apps/web/components/EncryptionJourney.tsx apps/web/components/EncryptionJourney.module.css apps/web/components/Button.tsx apps/web/components/Button.module.css apps/web/app/page.tsx apps/web/app/page.module.css apps/web/e2e/marketing.spec.ts
git commit -m "feat(web): rebuild homepage product story"
```

### Task 4: Full-Screen Interactive App Sandbox

**Files:**
- Create: `apps/web/components/AppSandbox/AppSandboxLauncher.tsx`
- Create: `apps/web/components/AppSandbox/AppSandbox.tsx`
- Create: `apps/web/components/AppSandbox/AppSandbox.module.css`
- Create: `apps/web/components/AppSandbox/screens.tsx`
- Create: `apps/web/components/AppSandbox/state.ts`
- Create: `apps/web/components/AppSandbox/types.ts`
- Modify: `apps/web/components/HomeHero.tsx`
- Modify: `apps/web/app/page.tsx`
- Modify: `apps/web/e2e/marketing.spec.ts`

**Interfaces:**
- `SandboxDestination = 'chats' | 'calls' | 'map' | 'moments' | 'clips' | 'games' | 'privacy'`.
- `SandboxState = { destination: SandboxDestination; chatSent: boolean; callActive: boolean; shareMinutes: 15 | 60; clipPlaying: boolean; selectedGame: 'snake' | 'cricket' | null }`.
- `sandboxReducer(state, action): SandboxState` supports `navigate`, `send-message`, `toggle-call`, `set-share-duration`, `toggle-clip`, `select-game`, and `reset`.
- `AppSandboxLauncher` dynamically imports `AppSandbox` only after activation.

- [ ] **Step 1: Write failing open/close/focus tests**

Test that clicking `Go through the app` creates a `role="dialog"` with an accessible name, locks page scroll, moves focus to Close, closes with Escape, removes scroll lock, and restores focus to the launch button.

- [ ] **Step 2: Write failing sandbox interaction tests**

Test destination buttons and one real interaction per family: send sample message, start/end sample call, choose 60-minute sharing, play/pause clip, select Snake, open privacy explanation, reset to Chats.

- [ ] **Step 3: Run sandbox tests and verify RED**

Run: `npm run test:e2e -w @voiid/web -- --grep "app sandbox"`

Expected: FAIL because no sandbox dialog exists.

- [ ] **Step 4: Implement reducer, types, and structured destinations**

Keep all deterministic behavior in `state.ts`; keep labels, helper copy, and screen composition in `screens.tsx`. Do not use timers to advance state and do not connect to APIs.

- [ ] **Step 5: Implement the lazy launcher**

Load the sandbox with `import('./AppSandbox')` only after the button is activated. While loading, show a compact `aria-live="polite"` status. If import fails, show Retry and a link to `#features`.

- [ ] **Step 6: Implement the accessible full-screen shell**

Use a portal, `role="dialog"`, `aria-modal="true"`, close/reset controls, destination rail, responsive phone canvas, focus containment, Escape handling, focus restoration, and body scroll locking with cleanup on every exit path.

- [ ] **Step 7: Implement the seven simulated screens**

Build small, branded screen components using existing glyphs and CSS shapes. Every glowing/clickable control must be a real button with text or an accessible name. Keep illustrations below the DOM complexity of the current full page and render only the active screen.

- [ ] **Step 8: Run sandbox tests and verify GREEN**

Run: `npm run test:e2e -w @voiid/web -- --grep "app sandbox"`

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add apps/web/components/AppSandbox apps/web/components/HomeHero.tsx apps/web/app/page.tsx apps/web/e2e/marketing.spec.ts
git commit -m "feat(web): add interactive app sandbox"
```

### Task 5: Homepage Feature Proof, Privacy Boundary, and Download Area

**Files:**
- Create: `apps/web/components/FeatureRail.tsx`
- Create: `apps/web/components/FeatureRail.module.css`
- Create: `apps/web/components/PrivacyBoundary.tsx`
- Create: `apps/web/components/PrivacyBoundary.module.css`
- Create: `apps/web/components/DownloadSection.tsx`
- Create: `apps/web/components/DownloadSection.module.css`
- Modify: `apps/web/app/page.tsx`
- Modify: `apps/web/app/page.module.css`
- Modify: `apps/web/components/SiteFooter.tsx`
- Modify: `apps/web/e2e/marketing.spec.ts`

**Interfaces:**
- `FeatureRail` consumes the existing `SURFACES` navigation data and links to feature routes.
- `PrivacyBoundary` consumes explicit `encrypted` and `serverReadable` string arrays.
- `DownloadSection` consumes `STORE_LINKS` and renders links only for non-null values.

- [ ] **Step 1: Expand failing tests for feature and download behavior**

Assert all feature routes are linked from the homepage, privacy lists have explicit headings, store placeholders are non-interactive, the QR card says `QR code will appear here`, and no empty/hash store anchor is present.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `npm run test:e2e -w @voiid/web -- --grep "feature rail|privacy boundary|store"`

Expected: FAIL.

- [ ] **Step 3: Build the feature rail and product proof cards**

Create a responsive rail/grid that varies card composition rather than repeating identical blocks. Use actual product UI fragments and concise search-friendly copy; keep links server rendered.

- [ ] **Step 4: Build the privacy boundary**

Present `End-to-end encrypted` and `Server-readable by design` as equal, clearly labelled columns. Do not use a green/red good/bad framing. Link to `/privacy` and `/encryption` for full explanations.

- [ ] **Step 5: Build the download section and footer handoff**

Render branded App Store and Google Play shapes without copying remote badge images. With null URLs, render disabled-looking status elements with `Coming soon`; with URLs, render external anchors. Add a rounded QR placeholder card that never pretends to contain a code.

- [ ] **Step 6: Finish homepage composition and responsive CSS**

Assemble hero, feature rail, encryption journey, privacy boundary, product proof, origin statement, and download section. Ensure section order and backgrounds remain coherent in light and dark modes.

- [ ] **Step 7: Run focused tests and verify GREEN**

Run: `npm run test:e2e -w @voiid/web -- --grep "feature rail|privacy boundary|store"`

Expected: PASS, including Task 1's previously red download fallback.

- [ ] **Step 8: Commit**

```bash
git add apps/web/components/FeatureRail.tsx apps/web/components/FeatureRail.module.css apps/web/components/PrivacyBoundary.tsx apps/web/components/PrivacyBoundary.module.css apps/web/components/DownloadSection.tsx apps/web/components/DownloadSection.module.css apps/web/app/page.tsx apps/web/app/page.module.css apps/web/components/SiteFooter.tsx apps/web/e2e/marketing.spec.ts
git commit -m "feat(web): complete homepage conversion path"
```

### Task 6: Redesign and Rewrite Every Public Feature Page

**Files:**
- Modify: `apps/web/app/messaging/page.tsx`
- Modify: `apps/web/app/messaging/page.module.css`
- Modify: `apps/web/app/calls/page.tsx`
- Modify: `apps/web/app/calls/page.module.css`
- Modify: `apps/web/app/map/page.tsx`
- Modify: `apps/web/app/map/page.module.css`
- Modify: `apps/web/app/clips/page.tsx`
- Modify: `apps/web/app/clips/page.module.css`
- Modify: `apps/web/app/games/page.tsx`
- Modify: `apps/web/app/games/page.module.css`
- Modify: `apps/web/app/encryption/page.tsx`
- Modify: `apps/web/app/encryption/page.module.css`
- Modify: `apps/web/app/privacy/page.tsx`
- Modify: `apps/web/app/privacy/page.module.css`
- Modify: `apps/web/app/invite/page.tsx`
- Modify: `apps/web/lib/nav.ts`
- Modify: `apps/web/e2e/marketing.spec.ts`

**Interfaces:**
- Every route exports unique `Metadata` with title, description, alternates.canonical, Open Graph title/description, and Twitter title/description.
- Every route has exactly one H1, one descriptive lead, at least one contextual link to another public route, and accurate privacy language.

- [ ] **Step 1: Write failing route-wide SEO and heading tests**

Iterate over the nine public routes and assert HTTP success, exactly one H1, non-duplicate titles/descriptions, canonical link, no horizontal overflow at 320px, and at least one internal contextual link outside the header/footer.

- [ ] **Step 2: Run route-wide tests and verify RED**

Run: `npm run test:e2e -w @voiid/web -- --grep "public routes"`

Expected: FAIL on missing canonical/social metadata and responsive/content differences.

- [ ] **Step 3: Rewrite navigation summaries**

Update `lib/nav.ts` to concise user-facing labels and blurbs. Keep current route names and privacy classifications stable.

- [ ] **Step 4: Rewrite and redesign messaging, calls, and map**

Use benefit-led headings, concrete UI proof, clear encryption notes, and contextual links. Keep call metadata and location expiry caveats explicit.

- [ ] **Step 5: Rewrite and redesign clips and games**

Lead with discovery/play value while stating public/server-refereed boundaries in visible copy. Keep the actual game catalogue accurate.

- [ ] **Step 6: Rewrite and redesign encryption and privacy**

Preserve technical accuracy while translating jargon into layered explanations. Keep named primitives in scannable evidence blocks and the complete data-visibility ledger.

- [ ] **Step 7: Redesign invite fallback**

Make `/invite` a polished public handoff that explains app availability honestly and points to the download section without inventing store links.

- [ ] **Step 8: Run route-wide tests and verify GREEN**

Run: `npm run test:e2e -w @voiid/web -- --grep "public routes"`

Expected: PASS for every public route at desktop and 320px.

- [ ] **Step 9: Commit**

```bash
git add apps/web/app/messaging apps/web/app/calls apps/web/app/map apps/web/app/clips apps/web/app/games apps/web/app/encryption apps/web/app/privacy apps/web/app/invite apps/web/lib/nav.ts apps/web/e2e/marketing.spec.ts
git commit -m "feat(web): redesign public feature pages"
```

### Task 7: Static SEO Files, Accessibility, Performance, and Visual Verification

**Files:**
- Create: `apps/web/app/robots.ts`
- Create: `apps/web/app/sitemap.ts`
- Modify: `apps/web/e2e/marketing.spec.ts`
- Modify: `apps/web/README.md`
- Modify: `apps/web/public/_headers`

**Interfaces:**
- `/robots.txt` allows public crawling and points to the absolute sitemap URL.
- `/sitemap.xml` includes every public route with stable absolute URLs.
- Static headers preserve CSP/security behavior without blocking inline theme bootstrap or JSON-LD.

- [ ] **Step 1: Write failing static SEO and accessibility tests**

Assert `/robots.txt` and `/sitemap.xml` output, keyboard access to header/theme/sandbox, sandbox focus containment, visible focus in both themes, reduced-motion final states, and no uncaught console errors.

- [ ] **Step 2: Run the tests and verify RED**

Run: `npm run test:e2e -w @voiid/web -- --grep "robots|sitemap|keyboard|console"`

Expected: FAIL because robots and sitemap routes do not exist.

- [ ] **Step 3: Implement robots and sitemap**

Use `MetadataRoute.Robots` and `MetadataRoute.Sitemap`, `SITE_URL`, and the canonical public route list. Keep dates deterministic rather than generating current timestamps at build time.

- [ ] **Step 4: Update security headers and documentation**

Document theme/store configuration, sandbox behavior, and verification commands. Adjust CSP only as narrowly as needed for the inline bootstrap/JSON-LD used by the static export.

- [ ] **Step 5: Run typecheck and production build**

Run:

```bash
npm run typecheck -w @voiid/web
npm run build -w @voiid/web
```

Expected: both exit 0 and `apps/web/out/` contains every route plus `robots.txt` and `sitemap.xml`.

- [ ] **Step 6: Run the complete browser suite**

Run: `npm run test:e2e -w @voiid/web`

Expected: all tests pass with no console errors.

- [ ] **Step 7: Perform responsive visual verification**

Inspect `/` and each route at 320, 375, 768, 1024, and 1440 CSS pixels in light and dark themes. Verify no clipping, unreadable overlap, horizontal page scroll, inaccessible control, or broken modal layout. Capture representative screenshots for the final handoff but do not commit transient output.

- [ ] **Step 8: Verify sandbox is absent from the initial page payload**

Inspect the production build manifests or browser network panel and confirm the AppSandbox client chunk is not fetched before the visitor activates `Go through the app`.

- [ ] **Step 9: Commit**

```bash
git add apps/web/app/robots.ts apps/web/app/sitemap.ts apps/web/e2e/marketing.spec.ts apps/web/README.md apps/web/public/_headers
git commit -m "feat(web): finish public site SEO and verification"
```


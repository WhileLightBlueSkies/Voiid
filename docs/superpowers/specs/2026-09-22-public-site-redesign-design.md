# Voiid Public Website Redesign

**Date:** 2026-09-22  
**Status:** Approved design  
**Scope:** `apps/web` only

## Goal

Rebuild Voiid's public marketing website as a fast, responsive, search-optimized product experience that explains the shipped product clearly, demonstrates it interactively, and prepares visitors to download the iOS or Android app when store links become available.

The redesign must not change `apps/web-client`, iOS, Android, backend, or any authenticated/client experience.

## Design Direction

The website uses a consistent rounded visual language across typography, buttons, navigation, cards, device frames, dialogs, and form-like controls.

- Light mode is the default and follows the approved “Calm confidence” direction: bright, premium, product-led, and trustworthy.
- Dark mode follows the approved “Immersive privacy” direction: deep green-black surfaces, luminous teal accents, and stronger encryption-focused motion.
- A visible theme control lets visitors switch modes. The first visit starts in light mode; subsequent visits restore the visitor's explicit choice.
- The theme must render without a visible flash and remain readable at every supported contrast level.
- Decorative visuals must be specific to Voiid: device interfaces, animated lock states, encrypted packet paths, privacy boundaries, and product interactions. Generic stock decoration is not used as the primary product proof.

## Information Architecture

Existing public routes remain available:

- `/`
- `/messaging`
- `/calls`
- `/map`
- `/clips`
- `/games`
- `/encryption`
- `/privacy`
- `/invite`

The header presents a concise product navigation, privacy/encryption access, the theme switch, and one primary download-oriented action. Mobile navigation is a real accessible disclosure and must not expose hidden links to keyboard or screen-reader users.

Every page uses the same design system but receives unique copy, page metadata, internal links, and product visuals. The footer retains required contact and grievance information while adding the download area.

## Homepage Experience

The homepage follows this order:

1. A product-first hero with concise positioning, a primary “Go through the app” action, a secondary feature action, and an animated multi-device product composition.
2. A fast feature overview for messaging, calls, map/location sharing, moments, clips, and games.
3. An interactive encryption illustration showing information being sealed on one device, travelling as ciphertext, and opening only on the intended device.
4. A privacy boundary section that states plainly which surfaces are end-to-end encrypted and which are server-readable by design.
5. A product proof section with clickable interface previews.
6. A download section containing App Store and Google Play placeholders, a reserved QR-code card, platform availability copy, and a clear way to replace placeholders with real URLs later.
7. The legal/contact footer.

The homepage avoids repeated generic headline/paragraph/card bands. Section composition changes according to the story being told while typography, spacing, and controls remain consistent.

## Full-Screen App Sandbox

The “Go through the app” button opens a full-viewport, lightweight simulation inside the marketing site. It does not open or modify the real application.

Visitors can freely jump between simulated screens for:

- Chats and group messaging
- Voice and video calls
- Live location sharing and map controls
- Moments
- Clips
- Games
- Privacy and encryption states

The simulation uses working buttons and deterministic local state. Examples include opening a conversation, sending a sample message, switching tabs, starting a sample call state, selecting a location-sharing duration, opening a clip, choosing a game, and viewing an encryption explanation.

The sandbox:

- loads its client-side code only after the visitor asks to open it;
- fills the viewport while preserving a clear close control;
- supports mouse, touch, keyboard, Escape, and visible focus;
- traps focus while open and restores focus to the launch button when closed;
- provides reset and direct screen-jump controls;
- prevents background scrolling;
- uses semantic buttons and status text instead of relying on color alone;
- provides a reduced-motion presentation that preserves all information;
- keeps its content in structured data so future screenshots or flows can replace individual simulations without rebuilding the shell.

## Copy and Product Accuracy

All public copy is rewritten in clear, natural language for prospective users rather than developers. It should be confident, concise, and specific without keyword stuffing.

Claims must preserve the existing verified boundaries:

- Messages, chat attachments, voice/video calls, live location shares, and moments sent to a known audience are end-to-end encrypted.
- Clips, creator activity, game state, and communication metadata are server-readable as documented by the current product architecture.
- The website must not advertise payments or any capability that is not reachable in the shipping product.
- Store availability must remain “Coming soon” until real URLs are provided.

## Search Optimization

Each route receives:

- a unique intent-focused title and meta description;
- one descriptive H1 and a semantic heading hierarchy;
- canonical metadata based on one configurable production site URL;
- Open Graph and social preview metadata;
- descriptive internal links and accessible image/graphic labels;
- structured data for the organization and software application where accurate;
- useful copy around encrypted messaging, private calls, secure location sharing, social clips, and in-chat games without repetitive keyword stuffing.

The static export includes `robots.txt` and `sitemap.xml`. Content remains present in server-rendered HTML; important copy is not hidden behind client-side interaction.

## Download Area

The download section is driven by a small configuration module containing nullable App Store and Google Play URLs.

- When a URL is absent, the relevant badge renders as a non-link “Coming soon” element.
- When a URL is added, the badge becomes a correctly labelled external link.
- The QR area renders a branded placeholder until a destination URL is provided.
- QR generation is deliberately deferred until the user supplies the final destination.
- Missing values never produce `#`, empty, or broken links.

## Performance

The site remains a static Next.js export and adds no analytics, trackers, webfont downloads, animation framework, or general-purpose component library.

- System rounded fonts avoid font downloads and layout shifts.
- Server components remain the default; client components are limited to theme control, mobile navigation, and the sandbox.
- The sandbox is dynamically loaded only after interaction.
- Decorative motion uses transform and opacity where possible.
- Heavy blur, continuous animation, and image density are reduced on smaller devices.
- Images use explicit dimensions, responsive sizing, and modern compressed formats when raster assets are needed.
- No page may rely on JavaScript for primary copy or navigation.
- The production build must complete as a static export.

## Accessibility and Responsive Behavior

The website supports narrow phones through large desktop displays without horizontal page scrolling.

- Tap targets are at least 44 by 44 CSS pixels where controls permit.
- Focus indicators remain visible in both themes.
- Text and essential controls meet WCAG AA contrast.
- Motion respects `prefers-reduced-motion`.
- Animations never carry essential information alone.
- Dialog and navigation state are announced correctly.
- Layouts are verified at 320, 375, 768, 1024, and 1440 CSS-pixel widths.

## Component Boundaries

The redesign uses focused components with clear responsibilities:

- theme bootstrap and switcher;
- site header and mobile navigation;
- homepage hero and product device composition;
- encryption path illustration;
- feature preview cards;
- app sandbox shell, navigation, screen renderer, and local interaction state;
- download/store section and QR placeholder;
- shared page metadata and structured-data helpers;
- footer and legal/contact content.

Page-specific content stays with its page. Reusable configuration covers navigation, feature summaries, store availability, and sandbox screens.

## Failure and Fallback Behavior

- If client-side JavaScript is unavailable, the public website remains readable and navigable; the sandbox trigger points visitors to the static feature overview.
- If the sandbox chunk fails to load, the dialog shows a concise retry message and a link to the feature pages.
- Missing store links display “Coming soon.”
- Reduced-motion mode replaces travelling/looping effects with clear static states.
- Unsupported theme persistence falls back to the default light theme.

## Verification

Implementation is complete only when all of the following pass:

- unit/component tests for theme choice, store-link fallbacks, and sandbox state transitions;
- interaction tests for opening, using, resetting, and closing the sandbox with keyboard and pointer input;
- checks for metadata, structured data, sitemap, and robots output;
- TypeScript type checking;
- production static export;
- responsive visual checks at the required widths in light and dark modes;
- accessibility checks for headings, names, focus order, dialog behavior, contrast, and reduced motion;
- a performance review confirming no new blocking external requests and that the sandbox remains out of the initial client bundle.

## Explicit Non-Goals

- No changes to the real Voiid app, web client, mobile clients, backend, authentication, or production data.
- No real App Store or Play Store URL before the user supplies it.
- No generated QR code before a destination is supplied.
- No analytics, lead form, newsletter, or tracker.
- No promotion of unshipped product capabilities.

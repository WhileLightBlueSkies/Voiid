# Voiid marketing site — brief

Queued behind the 10-topic repair effort (see docs/research/00_REPAIR_PLAN.md once the
research fleet lands). Written now so the palette and requirements don't get lost.

## What the founder asked for

A landing site with "the best graphics", **multiple pages**, in **our colour scheme**,
explaining **all the features** — built once the repair work is done.

## Where it lives

`apps/web` is already a workspace in the root package.json. Build it there (Next.js, same
as apps/admin-web, so the toolchain is uniform).

## The colour scheme (from apps/ios/Voiid/Voiid/DesignSystem/Theme.swift — the source of truth)

Dark is the DESIGNED state; light is the variant. The site should lead dark.

| Token | Light | Dark | Role |
|---|---|---|---|
| primary | `#2E2440` | `#B59BE0` | Deep aubergine — brand, every primary action |
| background | `#F1EEF5` | `#0D0B14` | The ground |
| surfaceCard | `#FFFFFF` | `#1C1826` | Cards, one step up |
| textPrimary | `#241D33` | `#E6E1EF` | |
| textSecondary | `#5F5570` | `#A79CBD` | |
| accent (amber) | `#B57210` | `#E8A33D` | The ONE warm counterweight — sparingly; its power is its rarity |
| divider | `#E3DEEC` | `#241F2F` | Must recede |

Domain hues (section identity — use to colour-code feature pages):
chat `#B59BE0` · stories `#C98BD8` · map `#7FB0E0` · calls `#5FBE8D` · payments `#E8A33D` (dark values).

## Pages (multiple, per the ask)

1. **Home** — hero, the E2EE promise in one line, feature grid, download CTAs
2. **Messaging** — E2EE chats, groups (1000 members), Note to Self, reachability/PIN model
   (the privacy story is the differentiator — tell it plainly)
3. **Calls** — 1:1, group voice/video, conference; E2EE
4. **Map** — friends map, live location (chat + group), Snapchat-grade accuracy, ghost mode
5. **Clips** — creator profiles, follows, filters; honest note that clips are public
6. **Games** — the catalog, invites
7. **Communities** — once the plan (docs/research/04_communities_plan.md) ships; hold the page until then
8. **Privacy** — the E2EE architecture in plain language + what we can and cannot see; DPDP posture
9. **Download / footer** — store links, contact, grievance officer (DPDP requires one)

## Positioning line the founder uses

"India's first app to go global." Lead with E2EE-everything + one app for chat, calls,
map, clips, games.

## Constraints

- Static/SSG — no server state; it's a brochure
- The privacy claims must match reality: messages/calls/locations/moments E2EE; clips,
  creator profiles and games deliberately public. Never overclaim.
- Graphics: draw from the app's real UI (screenshots/mockups in the real palette), not
  stock. Amber only for the single accent moment per page.

# Communities: features that look finished but don't work

> **Date:** 16 Sep 2026
> **Baseline:** `main` at `9fc79f3`
> **Scope:** everything the Communities feature shows a user, checked against what the backend can actually do. iOS, Android, backend, database.
> **Question:** which parts of Communities are visible in the app but do nothing, do less than they appear to, or differ between the two phones?
> **Related:** [COMMUNITY_PUBLIC_POST_ADMIN_ONLY_AUDIT_2026-09-15.md](COMMUNITY_PUBLIC_POST_ADMIN_ONLY_AUDIT_2026-09-15.md) covers who is allowed to post. Not repeated here.

---

## How to use this document

**Nothing here should be built without asking first.** Each finding ends with **Decisions needed**: the questions whose answers change what gets built. Bring those questions to Priyanshu, get the answers, then implement. The questions are the point of this document as much as the findings are.

---

## Summary

Communities is mostly real. Creating, joining, leaving, members, roles, bans, approvals, channels, invites, posts, likes, announcements, links, rules, events, tournaments, the host inbox and the moderation queue all talk to working endpoints.

What is broken is a thin layer of **controls that were drawn but never connected**, and a set of **screens that show invented information**:

- **Comments don't exist.** Posts show a comment count and a comment button on both phones. There is no comments table, no API, and the button does nothing.
- **Save and Share do nothing** on both phones, in the post menu and on the post card.
- **Report does nothing on Android.** iOS files a real report; Android's menu item only vibrates.
- **iOS invents member and Space details** the server never sent. Android deliberately shows less and is the honest one.
- **The admin dashboard's stats and task queue on iOS have no backend at all.**
- **"Keep this post" in the Android moderation queue** clears the row locally and the report comes back on refresh.
- **"Paid" communities** are shown as a "coming soon" row with nothing behind them.

Ten findings below, ordered by how visible the breakage is to a user.

### Labels

| Label | Meaning |
|---|---|
| **Dead control** | Visible, tappable, does nothing |
| **Invented data** | The screen shows information the server never sent |
| **Parity** | Works on one phone, not the other |
| **Not built** | Whole feature missing behind the UI that implies it |

Severity: **P1** users notice and it looks broken · **P2** misleading or inconsistent · **P3** cosmetic or internal.

---

## Findings

| ID | Sev | Type | Feature |
|---|---|---|---|
| [CM-01](#cm-01) | P1 | Not built | Comments on community posts |
| [CM-02](#cm-02) | P1 | Dead control | Share a post |
| [CM-03](#cm-03) | P1 | Dead control | Save a post |
| [CM-04](#cm-04) | P1 | Parity | Report a post does nothing on Android |
| [CM-05](#cm-05) | P2 | Invented data | iOS shows Space purpose, unread counts and member details the server never sent |
| [CM-06](#cm-06) | P2 | Not built | Admin dashboard stats and task queue on iOS |
| [CM-07](#cm-07) | P2 | Dead control | "Keep this post" in the Android moderation queue |
| [CM-08](#cm-08) | P2 | Not built | Paid communities |
| [CM-09](#cm-09) | P3 | Parity | Member display names resolve differently on each phone |
| [CM-10](#cm-10) | P3 | Not built | Member presence ("online now") |

---

<a id="cm-01"></a>
### CM-01 · P1 · Comments on community posts don't exist

**What the user sees.** Every post shows a speech-bubble icon with a number next to it. Tapping it does nothing, on both phones.

**Why.** The count is real and always zero: `community_posts` has a `comment_count` column ([047_community_home.sql:62](../../database/migrations/047_community_home.sql#L62)) that the posts API returns ([communities.ts:1914](../../backend/api/src/routes/communities.ts#L1914)). Nothing ever increments it, because there is no comments table, no comments endpoint, and no comment UI. Both apps know this and say so in code: iOS "there is nowhere for a tap to go... the button stays inert rather than opening an empty screen" ([CommunityHomeTab.swift:1089-1092](../../apps/ios/Voiid/Voiid/Main/CommunityHomeTab.swift#L1089-L1092)); Android's button just triggers a haptic tap ([CommunityHomeTab.kt:846-847](../../apps/android/app/src/main/java/com/voiid/app/main/CommunityHomeTab.kt#L846-L847)).

**What building it takes.** A `community_post_comments` table; endpoints to list, add and delete a comment; a rule for who may comment and who may delete; the count kept in step with the rows; a comment thread screen on both phones; moderation and reporting for comments; and a notification to the post author.

**Decisions needed**
1. Do comments ship at all, or should the button and count be removed for now? (Removing is a small change on both phones.)
2. Who may comment: any member, or only the people who may post (see the 15 Sep audit)?
3. Who may delete a comment: the author, community managers, both?
4. Are comments public like posts, or member-only?
5. Should the post author be notified? In-app only, or a push?
6. Do comments need reporting and a place in the moderation queue?
7. Editing, replies to comments, likes on comments: in or out for the first version?

---

<a id="cm-02"></a>
### CM-02 · P1 · Share a post does nothing

**What the user sees.** A Share button on every post card, and a Share item in the post's menu. Neither does anything on either phone.

**Why.** iOS passes no action at all for the card button ([CommunityHomeTab.swift:1093](../../apps/ios/Voiid/Voiid/Main/CommunityHomeTab.swift#L1093)) and the menu item has an empty body ([CommunityHomeTab.swift:1018](../../apps/ios/Voiid/Voiid/Main/CommunityHomeTab.swift#L1018)). Android's menu item closes the menu and vibrates ([CommunityHomeTab.kt:797-799](../../apps/android/app/src/main/java/com/voiid/app/main/CommunityHomeTab.kt#L797-L799)).

**What building it takes.** A shareable link for a post. Communities already have link handling (`CommunityLink.swift` / `CommunityLink.kt`) and route handles ([032_community_route_handles.sql](../../database/migrations/032_community_route_handles.sql)), so the piece to add is a per-post address, plus deciding what someone sees when they open it without being a member.

**Decisions needed**
1. Share to where: the system share sheet (any app), or forward inside Voiid to a chat, or both?
2. What is shared: a link, or a copy of the text?
3. Should a shared link open the post for a non-member, show a join screen, or refuse for private communities?
4. Should public-community posts be openable on the web, or only in the app?

---

<a id="cm-03"></a>
### CM-03 · P1 · Save a post does nothing

**What the user sees.** "Save post" in the post menu on both phones. Nothing happens, and there is no saved-posts list anywhere in the app.

**Why.** iOS has an empty action ([CommunityHomeTab.swift:1017](../../apps/ios/Voiid/Voiid/Main/CommunityHomeTab.swift#L1017)); Android vibrates and closes the menu ([CommunityHomeTab.kt:794-796](../../apps/android/app/src/main/java/com/voiid/app/main/CommunityHomeTab.kt#L794-L796)). There is no table, endpoint or screen for saved posts.

**What building it takes.** A saved-posts table keyed by user and post, endpoints to save, unsave and list, a place in the app to see saved posts, and a decision about what happens when a saved post is deleted.

**Decisions needed**
1. Ship saving, or remove the menu item for now?
2. Where do saved posts live: a section in the community, a global list in Settings or the profile?
3. Is saving private to the user? (Recommended: yes, and never shown to the community.)
4. What happens to a saved post when the author or a manager deletes it: disappears, or shows as removed?

---

<a id="cm-04"></a>
### CM-04 · P1 · Report a post does nothing on Android

**What the user sees.** Report in the post menu. On iOS it opens the report sheet and files a real report. On Android it closes the menu and vibrates.

**Why.** iOS calls through to the shared report sheet used by clips and profiles, against `community_post` ([CommunityHomeTab.swift:1019-1027](../../apps/ios/Voiid/Voiid/Main/CommunityHomeTab.swift#L1019-L1027)), and a comment there notes that an inert Report button is worse than none because it tells the reader their complaint was filed when nothing was written. Android's item has no call ([CommunityHomeTab.kt:800-802](../../apps/android/app/src/main/java/com/voiid/app/main/CommunityHomeTab.kt#L800-L802)).

Reported posts are what fills the managers' moderation queue ([communities.ts:2789-2800](../../backend/api/src/routes/communities.ts#L2789-L2800)), so an Android user's reports never reach a manager.

**What building it takes.** Wire the Android menu item to the existing reports API, the same way iOS does. This is the smallest fix in this document and needs no backend work.

**Decisions needed**
1. Confirm Android should match iOS exactly (same reasons list, same confirmation).
2. Should reporting also be available on announcements and, later, comments?

---

<a id="cm-05"></a>
### CM-05 · P2 · iOS shows Space and member details the server never sent

**What the user sees.** On iOS, a Space can show a purpose line and an unread count; the Members tab shows names and handles. Android shows a quieter screen with only what is real.

**Why.** iOS decorates real server rows with invented fields where the endpoint has no column, and documents it: "each row renders REAL server data where it exists and placeholder decoration where it does not" ([CommunityTabs.swift:15-34](../../apps/ios/Voiid/Voiid/Main/CommunityTabs.swift#L15-L34), `decorated(...)` at [CommunityTabs.swift:100](../../apps/ios/Voiid/Voiid/Main/CommunityTabs.swift#L100) and [CommunityTabs.swift:499](../../apps/ios/Voiid/Voiid/Main/CommunityTabs.swift#L499)). Android's author refused to port it: "Where a field has no endpoint, this screen omits it... The result is a quieter screen than the iOS one — and an honest one" ([CommunityTabs.kt:40-54](../../apps/android/app/src/main/java/com/voiid/app/main/CommunityTabs.kt#L40-L54)).

To iOS's credit, the worst of it is already gone: presence is no longer invented ([CommunityTabs.swift:508-511](../../apps/ios/Voiid/Voiid/Main/CommunityTabs.swift#L508-L511)). What remains is the announcement-channel purpose line, which is a fixed sentence the app writes, not the host's words ([CommunityTabs.swift:105-107](../../apps/ios/Voiid/Voiid/Main/CommunityTabs.swift#L105-L107)).

**What building it takes.** Either add the missing columns to the endpoints (a `purpose` on channels, a member count, unread counts) and show them for real, or remove the decoration on iOS so both phones show the same thing.

**Decisions needed**
1. Should Spaces have a host-written purpose/description? If yes, it needs a field in create and edit, plus the column.
2. Should a Space show a member count and unread badge? (Unread is available locally from the conversation; member count needs a query.)
3. Until those exist, should iOS drop the invented lines to match Android?

---

<a id="cm-06"></a>
### CM-06 · P2 · The iOS admin dashboard's stats and task queue have no backend

**What the user sees.** An admin opening a community on iOS sees a row of numbers and a task list at the top of Home.

**Why.** The file states it plainly: "the admin dashboard's stats and task queue are still placeholder — they have no backend at all" ([CommunityTabs.swift:20-21](../../apps/ios/Voiid/Voiid/Main/CommunityTabs.swift#L20-L21)).

There is a real stats endpoint ([communities.ts:2700](../../backend/api/src/routes/communities.ts#L2700)) and a real moderation queue ([communities.ts:2789](../../backend/api/src/routes/communities.ts#L2789)) — Android's Home tab uses both, including an open-reports count and a working queue ([CommunityHomeTab.kt:412](../../apps/android/app/src/main/java/com/voiid/app/main/CommunityHomeTab.kt#L412)). So on iOS this is wiring that was never finished, not a missing backend.

**Decisions needed**
1. Confirm iOS should use the same stats and moderation-queue endpoints Android already uses.
2. Which numbers belong on the dashboard: members, new members, posts, open reports, pending join requests?
3. Should the task queue be the moderation queue, or a wider to-do list (unanswered host messages, expiring invites)?

---

<a id="cm-07"></a>
### CM-07 · P2 · "Keep this post" in the Android moderation queue does nothing lasting

**What the user sees.** A manager reviewing a reported post taps "Keep this post". The row disappears, and comes back on the next refresh.

**Why.** It is a local dismissal with no endpoint behind it ([CommunityHomeTab.kt:160-164](../../apps/android/app/src/main/java/com/voiid/app/main/CommunityHomeTab.kt#L160-L164)). The other side of the decision works: deleting the post calls the real delete route. There is no way to mark a report as reviewed-and-dismissed, so the same report reappears forever.

**What building it takes.** An endpoint to resolve a report without deleting the post, storing who dismissed it and when, and excluding resolved reports from the queue.

**Decisions needed**
1. Should dismissing a report be permanent, or should a new report on the same post reopen it?
2. Should the reporter be told the outcome?
3. Does a dismissed report stay visible to managers as history, or disappear entirely?
4. Should repeated reports on a kept post escalate to Voiid staff (the existing `reports` path)?

---

<a id="cm-08"></a>
### CM-08 · P2 · Paid communities are advertised but not built

**What the user sees.** In community settings, under Joining, a "Paid" option greyed out with a "Coming soon" badge on both phones.

**Why.** It is deliberately not selectable, and both apps also refuse to send the value if a future edit makes the row tappable ([CommunitySettingsView.swift:145-151](../../apps/ios/Voiid/Voiid/Main/CommunitySettingsView.swift#L145-L151), [CommunityUI.kt:289-291](../../apps/android/app/src/main/java/com/voiid/app/main/CommunityUI.kt#L289-L291)). That part is well done: it fails safe.

Worth knowing: paid **events** already work (tickets, wallet, commission — [067_community_event_commission.sql](../../database/migrations/067_community_event_commission.sql), `routes/events.ts`), so payments exist in the product. Paid **membership** is the missing piece.

**Decisions needed**
1. Is paid membership a real plan, or should the row be removed so it stops being promised?
2. If real: one-time fee or recurring subscription?
3. What happens when someone stops paying: removed, or downgraded to limited access?
4. Who takes the commission, and at what rate? (Events already set a precedent.)
5. Which regulatory work applies? The Research folder's compliance notes should be consulted before any payment flow ships.

---

<a id="cm-09"></a>
### CM-09 · P3 · Member names resolve differently on each phone

**What the user sees.** The Members list shows names on iOS and id-derived avatars with role and join date on Android.

**Why.** The roster endpoint returns ids, usernames and states; iOS maps that into a display name and handle ([CommunityTabs.swift:499-505](../../apps/ios/Voiid/Voiid/Main/CommunityTabs.swift#L499-L505)), Android chose not to resolve names at all until the roster goes through its local directory ([CommunityTabs.kt:45-52](../../apps/android/app/src/main/java/com/voiid/app/main/CommunityTabs.kt#L45-L52)).

There is a privacy question underneath, and it is the same one the conference-call work settled: a community can contain strangers, and what a stranger may learn about you should be the @username, not your profile name.

**Decisions needed**
1. What may a member see about another member: @username only, or profile name for everyone?
2. Should saved contacts show the saved name, as call rosters do?
3. Should Android match iOS, or iOS match Android?

---

<a id="cm-10"></a>
### CM-10 · P3 · Member presence is not available

**What the user sees.** No "online now" dot anywhere in a community. This is currently correct.

**Why.** iOS used to invent it and the code now refuses: "a green dot is a claim about someone being there right now. Absent until the endpoint carries it" ([CommunityTabs.swift:508-511](../../apps/ios/Voiid/Voiid/Main/CommunityTabs.swift#L508-L511)). The roster endpoint carries no presence.

**Decisions needed**
1. Should communities show presence at all? (In a 48,000-member community it is noise, and it tells strangers when you are awake.)
2. If yes, only for saved contacts?

---

## Suggested order

| Phase | Why | Findings |
|---|---|---|
| 1 | Small fixes that stop the app lying to users | CM-04 (Android report), then decide remove-or-build for CM-02, CM-03 |
| 2 | Finish what the backend already supports | CM-06 (iOS dashboard wiring), CM-07 (dismiss a report) |
| 3 | The one real feature | CM-01 (comments), once its seven questions are answered |
| 4 | Consistency and honesty | CM-05, CM-09, CM-10 |
| 5 | Product decision first, build later | CM-08 (paid communities) |

---

## What this audit checked

**Read:** the communities router (all 47 endpoints) and its helper modules; migrations 030, 032, 046, 047, 053, 055, 066, 067; the host-threads router; both platforms' `CommunityService`, Home tab, Tabs, Settings, Detail, Create flow, Inbox, Events and Tournaments sections; the community admin surfaces.

**Method:** every control in the community UI was traced to the endpoint behind it; anything with no endpoint, an empty action or invented data was recorded.

**Not done:** no app was run and no live community was exercised. This is a source audit, so it finds controls that cannot work; it does not prove that the controls which are wired do work end to end.

**Already covered elsewhere:** who may publish a public post ([15 Sep audit](COMMUNITY_PUBLIC_POST_ADMIN_ONLY_AUDIT_2026-09-15.md)).

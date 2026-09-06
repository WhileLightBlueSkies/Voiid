# 10 — Web and admin correctness

Baseline: `a2e24e5` · 2026-09-05 · All tasks TODO; fixes specified, not implemented.

## W01 — Respect Cancel when resolving a report

**Priority:** P1 · **Evidence:** Confirmed · **Dependencies:** None

**Location:** `apps/admin-web/app/reports/page.tsx:31`, `:35`, `:36`.

`window.prompt(...)?.trim() ?? ''` converts Cancel into an empty note and still posts resolution. The UI performs the action after the operator cancels.

**Fix:** distinguish null from an intentionally empty note before mutation. Reset the selector after cancellation, prevent concurrent actions on the same report, and retain errors without pretending resolution succeeded. A small accessible dialog can replace prompt if needed; keep the selected report/resolution explicit.

**Done when:** Cancel and Escape issue zero requests; confirming an empty note submits once; error/retry cannot resolve another row or leave misleading selection. Test through the actual event handler.

## W02 — Prevent stale admin list responses overwriting new filters

**Priority:** P1 · **Evidence:** Confirmed race risk · **Dependencies:** None

**Location:** `apps/admin-web/components/useList.ts:28`, `:33`, `:35`, `:45`; `apps/admin-web/lib/api.ts`.

The debounce clears only a timer; an already-started fetch can finish after a newer filter request and replace its rows/cursor/error. Load-more can append from an obsolete query.

**Fix:** pass AbortSignal through the API helper and cancel obsolete requests. Also use a request generation/query identity check before every state update, including finally/error. Associate pagination cursors with their query; deduplicate appended rows by stable ID; serialize/load-lock load-more. Preserve existing visible data or show a clearly labeled loading state during filter changes.

**Done when:** delayed A completes after B without altering B's rows/cursor; rapid filters/reload/more are deterministic; unmount produces no stale updates; cancelled fetches do not show failure banners.

## W03 — Remove closed mobile navigation from the focus order

**Priority:** P1 · **Evidence:** Confirmed markup/style gap · **Dependencies:** Local web dependencies

**Location:** `apps/web/components/SiteHeader.tsx` (checkbox disclosure); `SiteHeader.module.css:294`, `:302`, `:347`.

Closed mobile navigation uses zero grid height plus overflow clipping. Its links still exist as focusable elements, and the checkbox-based control does not expose the usual expanded button state.

**Fix:** use a semantic button with `aria-expanded`/`aria-controls`, keep collapsed navigation hidden/inert and out of keyboard navigation, and provide Escape/route-change close and focus restoration. Preserve desktop navigation at breakpoint transitions. Keep the existing 180ms menu entrance and shared ease-out token; respect reduced motion. Do not mark desktop navigation inert based on stale mobile state.

**Done when:** keyboard traversal never reaches invisible links; screen readers announce expanded/collapsed state; opening/closing and resizing preserve focus; no hydration warnings. Verify with browser accessibility inspection and an automated navigation interaction test.

**Validation prerequisites:** both web applications lack installed React/Next dependencies in this checkout. Restore workspace dependencies in an isolated execution environment before calling their compile output a source defect. Preserve existing CSS reduced-motion and reduced-transparency handling where it already works.

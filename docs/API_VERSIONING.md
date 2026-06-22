# VOIID — API Versioning & Client Compatibility

How VOIID ships backend changes without breaking installed apps. Four pillars:
**path versioning**, **additive schema evolution**, **remote config / version
negotiation**, and **force-update gating**. Plus **SDUI scoped to clips only**.

## 1. Path versioning
Every API route is served under a version prefix: `/v1/...` (e.g. `/v1/messages/send`).
- `/v1` is a **stable contract** — once shipped, its response shapes never change.
- A breaking change ships as a **new** version (`/v2`) mounted alongside `/v1`.
- Implementation: `backend/api/src/index.ts` mounts one router at `/v1` **and** at
  the legacy root (so pre-versioning builds keep working during migration; remove
  the root alias once all clients send `/v1`).
- Clients prepend the version automatically (`APIConfig.apiVersion` / `ApiConfig.apiVersion`).

## 2. Additive schema evolution (within a version)
Inside a version, **only additive changes**:
- ✅ add new **optional** fields / nested objects.
- ❌ never remove, rename, or retype an existing field; never make optional→required.
- New features inside chat (calls, voice notes, reactions) arrive as optional
  fields so old `/v1` clients ignore them and keep working until migrated.
- Both clients already ignore unknown fields (`ignoreUnknownKeys` / non-strict decoders).

## 3. Remote config / version negotiation — `GET /config`
Unversioned + ungated (reachable even by a build that must update). On launch the
app fetches it (`ConfigService`) and learns:
```jsonc
{
  "api_version": "v1",
  "supported_api_versions": ["v1"],
  "min_supported_app": { "ios": "1.0.0", "android": "1.0.0" },
  "force_update": false,                 // computed for THIS caller from its headers
  "store_url": { "ios": "...", "android": "..." },
  "feature_flags": { "groups": false, "calls": false, "clips": false, ... },
  "sdui": { "clips_enabled": false, "version": 0, "screens": {} }
}
```
Flip features / versions server-side (env or code in `version.ts` / `config.ts`) with
no app release. Gate optional UI on `ConfigService.isEnabled("...")`.

## 4. Force-update gating by client version
Every request carries the client's identity via headers:
```
X-Voiid-Platform     ios | android
X-Voiid-App-Version  e.g. 1.4.2
X-Voiid-Api-Version  e.g. v1
```
`forceUpdateGate` (in `version.ts`) compares the app version to the per-platform
minimum. Below it → **HTTP 426** with a structured body
(`{ error:"update_required", min_supported_app, update_url }`). Both apps catch 426
globally and show a **blocking update screen** (iOS `voiidForceUpdateGate()` /
Android `UpdateRequiredScreen`).
- Raise the bar via env without a deploy: `MIN_APP_IOS`, `MIN_APP_ANDROID`.
- Hard cutoff for pre-versioning builds (which send no version): `FORCE_CUTOFF` (ISO date).
- Only users below the threshold are gated — not everyone.

## 5. Server-Driven UI — clips/video ONLY
SDUI is **scoped to the clips/short-video surface** so we can iterate on video UX
without app updates. The seam exists today in `/config.sdui` (`clips_enabled:false`
→ apps render native fallback). **Everything else stays native and hardcoded** —
calls, groups, auth, navigation, and ALL encryption / message-handling logic are
never server-driven.
> Status: **deferred** until Clips is actually built (it's still DummyData). Don't
> build the SDUI renderer for a screen that doesn't exist yet — the `/config` block
> is the placeholder to fill in then.

## Files
- Backend: `version.ts` (constants, semver, gate), `routes/config.ts`, `index.ts` (mount).
- iOS: `APIClient.swift` (headers + `/v1` + 426), `ConfigService.swift` (fetch + gate UI).
- Android: `ApiClient.kt` (headers + `/v1` + 426 + `UpdateGate`), `ConfigService.kt`,
  `MainActivity.kt` (root gate). `buildConfig=true` for `BuildConfig.VERSION_NAME`.

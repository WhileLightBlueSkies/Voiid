# Face Filters — Ground-Up Rebuild Spec

**Status:** approved design, not yet implemented
**Date:** 2026-09-19
**Scope:** `apps/ios` + `apps/android` — Clips camera face filters
**Supersedes:** `ClipFaceEffects.swift` and `ClipFaceEffects.kt` in their entirety

---

## 0. Read this first (instructions for the implementing agent)

This document is written to be executed by an agent that has not seen the
conversation that produced it. Work through it in order.

**Rules of engagement:**

1. **Do not start at §13.** Read §1–§6 first. The render math in §6 is the
   contract that both platforms implement; if you write platform code before
   you understand it, the two platforms will diverge and parity is
   unrecoverable.
2. **Phases in §13 are sequential and each has an exit criterion.** Do not
   begin phase N+1 until phase N's exit criterion has been demonstrated with
   real output — a screenshot, a measured frame time, a passing test. Not "the
   code looks right."
3. **Numbers marked `[CALIBRATE]` are starting values, not truths.** They have
   an associated calibration task in §13. Ship the calibrated value, not the
   placeholder.
4. **Delete the old code. Do not adapt it.** The two existing files total 2,758
   lines of hand-drawn Bézier art and 10-scalar tracking. There is nothing in
   them worth carrying forward except the One Euro filter (§5.4), which is
   correct and should be ported verbatim.
5. **Parity is enforced mechanically, not by discipline.** The filter
   definitions live in one place (§10) and both platforms read the same JSON.
   If you find yourself writing a per-platform `when`/`switch` over filter IDs,
   stop — that is the bug the old code died of.

---

## 1. What exists today, and the four reasons it fails

### 1.1 Inventory

| | iOS | Android |
|---|---|---|
| File | `apps/ios/Voiid/Voiid/Main/Clips/ClipFaceEffects.swift` (1,523 ln) | `apps/android/.../clips/ClipFaceEffects.kt` (1,235 ln) |
| Tracker | `VNDetectFaceLandmarksRequest`, 65-point constellation | ML Kit `FaceDetection`, contours ALL |
| Face model | none — 10 scalars | none — 10 scalars |
| Art | procedural `CGContext` Bézier paths | procedural Compose `Path` |
| Composite | `CIImage.composited(over:)` chain → `MTKView` | Compose `Canvas` overlay on `PreviewView` |
| Reaches the recording | yes, via `AVAssetWriter` | **no** |
| Filters | 12 | 12 |

### 1.2 Root cause 1 — there is no face mesh

Both platforms reduce the face to ten numbers:

```swift
struct TrackedFace {
    let box, eyeMid, eyeDistance, roll, yaw, pitch, nose, mouthMid: ...
    let mouthOpenness, smilingRatio: CGFloat
}
```

Ten scalars describe *where a face is*. They do not describe *what shape it
is*. Every capability the brief asks for — face mapping, makeup that follows
skin, warps, beauty retouch, occlusion — requires per-vertex geometry. With
ten scalars the only possible operation is "paste a flat image near the eyes,"
which is precisely what both files do. **This is the single root cause of "no
face mapping."**

### 1.3 Root cause 2 — the 3D pose is a heuristic, not a solve

`ClipFaceEffects.swift:300-310` recovers yaw by comparing nose-to-eye
distances:

```swift
let eyeRatio = (dR - dL) / total
if abs(yaw) < 0.05 { yaw = min(0.60, max(-0.60, eyeRatio * 0.50)) }
```

The magic `0.50` is a guess, the `±0.60` clamp silently caps head rotation at
about 34°, and the whole branch only runs when Vision's own yaw is already
near zero. Pitch is taken from Vision unfiltered. There is no camera intrinsic
model anywhere, so nothing in the system knows how a real object at a real
depth would project. **This is the root cause of "no depth perception."**

Everything downstream is 2D affine — `CGAffineTransform` on iOS,
`DrawScope.rotate/scale` on Android — with fake foreshortening bolted on:

```swift
let scaleX = baseScale * max(0.70, cosYaw)   // clamped, so it never
let scaleY = baseScale * max(0.75, cos(pitch * 0.6))  // fully foreshortens
let skewX  = tan(face.yaw * 0.18)            // shear ≠ perspective
```

A shear is not a perspective divide. Props will always read as stickers.

### 1.4 Root cause 3 — the art is source code

2,758 lines of hand-authored Bézier paths. Nobody has ever shipped
competitive filter art this way, because the medium cannot express it: no
gradients along a path, no soft shadows, no texture, no sub-pixel detail, and
every change requires a compile. The art is bad because the pipeline makes
good art impossible.

### 1.5 Root cause 4 — Android filters never reach the file

`apps/android/.../ClipCameraView.kt:305-310` states it plainly:

> `* it is DISPLAY ONLY. The frames CameraX hands VideoCapture never see it, so recording stays clean`

That reasoning is correct for the **colour** filter, which is deliberately
re-applied at export by `Transformer`. It is wrong for **face** effects,
because nothing re-applies them: `grep -n faceEffect ClipEditor.kt
ClipComposerFlow.kt` returns zero hits. An Android user selects a filter, sees
it in the viewfinder, records, and gets a clip with no filter on it. This is a
correctness bug, not a quality complaint, and it is the highest-severity item
in this document.

### 1.6 Why it is slow

**iOS** — `ClipFaceDetector.copy()` runs a full CoreImage CPU render into a
freshly allocated 720p BGRA buffer for *every frame submitted to the tracker*,
then throws the buffer away:

```swift
copyContext.render(image, to: dest)   // full CPU blit, every frame
```

Then `ClipFaceRenderer.apply` rebuilds a `composited(over:)` chain per frame,
forcing CoreImage to re-plan its graph each time.

**Android** — the most expensive ML Kit configuration available
(`CONTOUR_MODE_ALL` + `CLASSIFICATION_MODE_ALL` + `LANDMARK_MODE_ALL`) runs at
frame rate, and the overlay re-tessellates every vector path on the UI thread
inside a Compose `Canvas` every frame.

Both are fixed structurally by the new pipeline: the tracker gets a GPU
texture with no copy, and all drawing is a fixed set of pre-compiled GPU passes.

---

## 2. How the industry actually does this

Snapchat, Instagram/Spark AR, TikTok/Effect House and the commercial SDKs
(Banuba, DeepAR) all converge on the same five-stage architecture. Nothing
below is exotic; it is the standard shape.

1. **Dense morphable face mesh.** A fixed-topology mesh of a few hundred to a
   few thousand vertices is regressed per frame. Fixed topology is the whole
   trick: vertex 33 is the left eye's outer corner on *every* face, so an
   artist can author against it once. Snap and Spark both expose the mesh to
   artists as a UV-unwrapped template.
2. **Blendshape (action unit) coefficients.** 52 normalised expression scores —
   `jawOpen`, `eyeBlinkLeft`, `browInnerUp`. Effects bind to these declaratively
   rather than hand-thresholding landmark distances. ARKit defined the naming
   that MediaPipe and the SDKs now mirror.
3. **True 6DoF pose via a metric head model.** Either a PnP solve of the 2D
   landmarks against a canonical 3D head, or a directly regressed
   transformation matrix. The output is a 4×4 that places a metric head model
   in camera space, and props are then placed **in head-local units and
   projected through a real perspective matrix**. This — not a shear — is what
   produces depth.
4. **Occlusion from the mesh.** The face mesh plus a skull proxy is rendered
   into the depth buffer with colour writes disabled. Props then depth-test
   against it for free, so a glasses arm disappears behind the cheek and hat
   brims sit correctly against the forehead.
5. **Effects are data, not code.** A manifest binds layers to mesh anchors,
   blendshapes and physics. The renderer is a fixed interpreter; new filters
   are new manifests. This is what makes 20 filters cost about the same
   engineering as 2.

**What we adopt:** all five.
**What we skip:** hair segmentation, cloth simulation, world-space AR, and a
node-graph authoring tool. None are needed for the 20 launch filters, and each
is a project of its own.

---

## 3. Decisions already made — treat as locked

These were decided with the product owner. Do not revisit them; if one turns
out to be infeasible, stop and escalate rather than substituting.

| # | Decision | Rationale |
|---|---|---|
| D1 | **MediaPipe Face Landmarker on both platforms** | One model → one geometry → one manifest. 478 landmarks, 52 blendshapes, and a 4×4 facial transformation matrix, so no PnP solve is needed. ~3.2 MB, GPU delegate. ARKit is *not* used: it is TrueDepth-only, front-camera-only, and a second geometry would mean authoring every filter twice. |
| D2 | **Shared GPU pipeline — Metal (iOS) + OpenGL ES 3.0 (Android)** | Same pass structure, shader sources kept line-for-line parallel. Renders into the camera texture so preview and recording are one path. Adds no binary weight. No RealityKit/Filament (≈4–8 MB and two different looks); no commercial SDK (per-MAU cost, 10–40 MB, vendor-locked format). |
| D3 | **9 filters bundled, 11 CDN-delivered** | Install grows ~3.6 MB. Every shader-only filter (8 of them) costs ~0 MB and ships in the binary; the 11 asset-backed prop packs download on first tap and sit in a 40 MB LRU cache. Directly serves "don't make the app heavy." *(The decision was framed as ~6 bundled when the mix was 5 beauty + 5 warp; D4's prop-heavy mix leaves 8 shader-only filters, and bundling a zero-cost filter is strictly better than downloading it.)* |
| D4 | **Prop-heavy mix: 12 props, 4 beauty, 4 warp** | Matches what users expect from the category. Full list in §9. |

**Platform floors** (verified in-repo): iOS deployment target **18.0**
(`project.pbxproj:592`); Android **minSdk 24, compileSdk 36**
(`app/build.gradle.kts:50-61`). OpenGL ES 3.0 is safe at API 24. AGSL is API 33+
and therefore **not usable** — all Android shaders are GLSL ES 3.0.

---

## 4. Target architecture

```
                       ┌─────────────────────────────────────┐
  camera frame ───────►│ CAPTURE  zero-copy → GPU texture    │
  (AVCapture /         │  iOS: CVMetalTextureCache           │
   CameraX Effect)     │  Android: GL_TEXTURE_EXTERNAL_OES   │
                       └───────┬─────────────────────┬───────┘
                               │                     │
                 (downscaled copy, tracker thread)   │ (full res, render thread)
                               ▼                     │
                  ┌────────────────────────┐         │
                  │ TRACK  MediaPipe        │         │
                  │  478 verts (3D)         │         │
                  │  52 blendshapes         │         │
                  │  4×4 transform matrix   │         │
                  │  ~24 Hz, own thread     │         │
                  └───────────┬────────────┘         │
                              ▼                      │
                  ┌────────────────────────┐         │
                  │ STABILISE               │         │
                  │  One Euro + velocity    │         │
                  │  extrapolation → 60 Hz  │         │
                  └───────────┬────────────┘         │
                              │  FaceFrame            │
                              ▼                      ▼
                  ┌──────────────────────────────────────────┐
                  │ RENDER  fixed pass chain (§6)            │
                  │  P1 beauty → P2 colour → P3 warp →       │
                  │  P4 face-texture → P5 occluder-depth →   │
                  │  P6 props → P7 ambient                   │
                  │  driven entirely by FXManifest (§5.5)    │
                  └───────────┬──────────────────────────────┘
                              │  one output texture
                  ┌───────────┴───────────┐
                  ▼                       ▼
            preview surface          video encoder
                                   (same pixels, guaranteed)
```

### 4.1 Threading contract

| Thread | Owns | Must never |
|---|---|---|
| Camera | frame delivery, texture upload | block; allocate |
| Tracker | MediaPipe inference | touch GPU render state |
| Render | all passes, both outputs | call into MediaPipe |
| Main/UI | filter selection, download UI | touch the GL/Metal context |

The tracker publishes a `FaceFrame` into a single-slot mailbox (latest wins,
lock-free double buffer). The render thread reads whatever is there and
extrapolates. Dropping tracker frames is normal and correct; dropping render
frames is not.

### 4.2 Files to create

**iOS** — `apps/ios/Voiid/Voiid/Main/Clips/FaceFX/`

| File | Responsibility |
|---|---|
| `FaceFXEngine.swift` | Public façade. `attach(session:)`, `select(filterId:)`, `render(into:)`. The only type the camera code sees. |
| `FaceTracker.swift` | MediaPipe wrapper, own queue, publishes `FaceFrame`. |
| `FaceGeometry.swift` | Canonical model, index tables, projection matrix, anchor resolution. |
| `PoseStabilizer.swift` | One Euro + extrapolation. Port of the existing filter. |
| `FXManifest.swift` | `Codable` manifest types + validation. |
| `FXAssetStore.swift` | Bundled + CDN packs, LRU cache, SHA-256 verify. |
| `FXRenderer.swift` | Pass orchestration, pipeline-state cache. |
| `FXDeviceTier.swift` | Tier measurement + dynamic downgrade. |
| `Shaders/FaceFX.metal` | All passes. |

**Android** — `apps/android/app/src/main/java/com/voiid/app/main/clips/facefx/`

| File | Responsibility |
|---|---|
| `FaceFxEngine.kt` | Public façade, mirrors `FaceFXEngine`. |
| `FaceFxEffect.kt` | `CameraEffect` + `SurfaceProcessor` — the piece that gets the filter into the recording. |
| `FaceTracker.kt` | MediaPipe wrapper, `HandlerThread`. |
| `FaceGeometry.kt` | Mirror of `FaceGeometry.swift`. |
| `PoseStabilizer.kt` | Mirror of `PoseStabilizer.swift`. |
| `FxManifest.kt` | Manifest types + validation. |
| `FxAssetStore.kt` | Mirror of `FXAssetStore.swift`. |
| `FxRenderer.kt` | Pass orchestration. |
| `GlProgram.kt`, `GlFramebuffer.kt` | Thin GL ES 3.0 helpers. |
| `FxDeviceTier.kt` | Mirror of `FXDeviceTier.swift`. |
| `assets/facefx/shaders/*.glsl` | All passes, one file per pass. |

**Shared** — `packages/facefx/`

| Path | Contents |
|---|---|
| `manifests/*.json` | 20 filter manifests — the single source of truth. |
| `art/` | Source artwork (SVG/PSD), not shipped. |
| `luts/*.cube` | Colour grades, authored once. |
| `canonical/face_model.json` | Canonical vertices, UVs, triangle indices. |
| `build/pack.mjs` | Builds `.voiidfx` packs, atlases, LUT strips. |
| `build/validate.mjs` | Schema + anchor-index validation. |

**Tooling** — `tools/check-facefx-parity.py`, following the existing
`tools/check-*.py` convention. Fails CI when the two platforms' bundled filter
ID lists, manifest versions, or pass orders disagree.

---

## 5. Data contracts

### 5.1 `FaceFrame`

The one structure the tracker produces and the renderer consumes. Identical
fields, identical units, on both platforms.

```
FaceFrame {
    timestampNanos : Int64      // capture time, not receipt time
    valid          : Bool       // false = no face; renderer shows clean camera

    vertices       : [Vec3 × 478]   // canonical-model space, centimetres
    blendshapes    : [Float × 52]   // 0…1, order per Appendix B
    headMatrix     : Mat4x4         // canonical space → metric camera space

    imageWidth     : Int
    imageHeight    : Int
    mirrored       : Bool       // front camera
}
```

**Unit discipline.** `vertices` are in centimetres in canonical-model space,
origin near the nose bridge. `headMatrix` maps that into metric camera space.
Prop offsets in manifests are **also centimetres in canonical-model space**, so
they are applied *before* `headMatrix` and inherit head rotation for free.
This is the mechanism that produces real 3D placement — see §6.7.

### 5.2 Projection

MediaPipe's transformation matrix is defined against a specific virtual camera.
Reproduce it exactly or props will drift as the head moves toward the frame
edges:

```
fovY   = 63°            [CALIBRATE — see §13 Phase 2]
aspect = imageWidth / imageHeight
near   = 1.0            // centimetres
far    = 10000.0

P = perspective(fovY, aspect, near, far)     // right-handed, looking down −Z
```

Any point in canonical space projects as:

```
clip = P · headMatrix · vec4(pointInCanonicalCm, 1.0)
ndc  = clip.xyz / clip.w
```

**Calibration test (mandatory, Phase 2).** Project all 478 canonical vertices
through `P · headMatrix` and compare against the 2D landmark positions
MediaPipe reports directly. Mean reprojection error must be **< 2 px at
720p**. If it is not, `fovY` is wrong — sweep it from 55° to 70° in 0.5° steps
and take the minimum. Do not proceed past Phase 2 with a failing calibration;
every downstream placement depends on it.

### 5.3 Anchors

An anchor is a barycentric blend of canonical vertices plus a head-local offset:

```
anchorCm = Σ(weight_i · vertices[index_i]) + offsetCm
```

Weights must sum to 1.0 (validated at load). Using three vertices rather than
one makes the anchor robust to any single landmark's jitter.

### 5.4 Stabilisation and latency hiding

The tracker runs at ~24 Hz; the display runs at 60 Hz. Without prediction,
every filter lags the face by 40–60 ms, which reads as "floaty" — a large part
of why the current filters feel wrong even when placement is correct.

**Step 1 — One Euro filter.** Port verbatim from
`ClipFaceEffects.swift:152-185`. The existing implementation is correct. Apply
per-component to `headMatrix`'s translation and rotation (as a quaternion) and
to each blendshape. Do **not** filter the 478 vertices individually — filter
the matrix and the blendshapes, and re-derive vertices.

Starting cutoffs (ported from the existing tuning, which is reasonable):

| Signal | minCutoff | beta |
|---|---|---|
| translation | 1.8 | 0.02 |
| rotation | 2.2 | 0.12 |
| blendshapes | 3.2 | 0.22 |

**Step 2 — velocity extrapolation.**

```
keep the last 3 (pose, timestamp) pairs
v = (pose[n] − pose[n−1]) / (t[n] − t[n−1])
dt = clamp(now − t[n], 0, 50ms)
predicted = pose[n] + v · dt
```

Clamp predicted translation to **0.15 × inter-ocular distance** from
`pose[n]`. Slerp rotations rather than lerping the matrix. Extrapolation is
what turns 24 Hz tracking into 60 Hz-feeling motion; the clamp is what stops
it overshooting on fast turns.

**Step 3 — re-acquisition.** On `valid` going false→true, or a jump over
`1.2 × interocular` or a 40 % scale change in one frame, **reset the filter
state** rather than smoothing across the discontinuity. The existing code does
this correctly at `ClipFaceEffects.swift:385-390`; keep that behaviour.

### 5.5 Manifest schema

The contract between artists and the renderer. Both platforms parse this; no
filter behaviour may exist outside it.

```jsonc
{
  "schema": 1,
  "id": "puppy",                 // stable, lowercase, matches pack filename
  "version": 3,                  // bump on any change; drives cache busting
  "name": "Puppy",               // user-visible
  "tier": 2,                     // min device tier required (§11)
  "atlas": "puppy.webp",         // omit for shader-only filters
  "lut": null,                   // or "film.png"

  "passes": ["occluder", "props"],   // subset of §6, always in §6's order

  "beauty":  { "smooth": 0.35, "brighten": 0.05 },
  "colour":  { "lut": null, "saturation": 1.0, "contrast": 1.0 },

  "warps": [
    {
      "id": "eyes",
      "anchor": { "indices": [33, 133, 159], "weights": [0.34, 0.33, 0.33] },
      "radiusCm": 2.2,
      "mode": "magnify",         // magnify | pinch | translate
      "strength": 0.28,
      "direction": [0, 0]        // translate mode only, canonical XY
    }
  ],

  "faceTextures": [
    { "id": "stripes", "atlasRect": [0, 512, 512, 512], "opacity": 0.85,
      "blend": "multiply" }      // normal | multiply | screen | overlay
  ],

  "layers": [
    {
      "id": "ear_left",
      "type": "quad",
      "atlasRect": [0, 0, 256, 256],        // px in atlas
      "anchor": { "indices": [54, 103, 67], "weights": [0.4, 0.3, 0.3] },
      "offsetCm": [0.0, 2.5, -1.0],         // canonical space, applied pre-matrix
      "sizeCm": [6.0, 7.0],
      "rotationDeg": [0, 0, -12],
      "billboard": "none",                   // none | y | full
      "depthTest": true,
      "depthWrite": true,
      "order": 10,                           // ascending; ties broken by index

      "physics": {
        "type": "spring", "driver": "headRollVelocity",
        "stiffness": 160, "damping": 12, "maxDeg": 18
      },

      "bindings": [
        { "blendshape": "jawOpen", "target": "scale.y",
          "inRange": [0.0, 0.6], "outRange": [1.0, 1.35] },
        { "blendshape": "mouthSmileLeft", "target": "opacity",
          "inRange": [0.2, 0.8], "outRange": [0.0, 1.0] }
      ]
    }
  ],

  "particles": [
    {
      "id": "confetti",
      "atlasRect": [512, 0, 128, 128],
      "emitAnchor": { "indices": [13, 14, 0], "weights": [0.4, 0.4, 0.2] },
      "trigger": { "blendshape": "jawOpen", "above": 0.45 },
      "rate": 60, "lifetimeMs": 1200, "gravityCm": [0, -18, 0],
      "speedCm": [8, 16], "maxParticles": 120
    }
  ]
}
```

**Binding targets:** `scale.x`, `scale.y`, `scale.uniform`, `opacity`,
`offset.x`, `offset.y`, `offset.z`, `rotation.z`, `atlasFrame`.
Evaluation: `out = lerp(outRange[0], outRange[1], smoothstep(inRange[0], inRange[1], value))`.
Multiple bindings on one target multiply for scale/opacity and sum for offsets.

**Validation at load (both platforms, `validate.mjs` in CI):** schema version
known; every anchor index in `0…477`; weights sum to `1.0 ± 0.001`; every
`atlasRect` inside the atlas; `passes` a subset of §6 in §6's order; every
blendshape name in Appendix B; `order` unique within a manifest.
**A manifest that fails validation is skipped with a logged error — never
partially applied.**

---

## 6. The render pipeline

Fixed order. A filter selects a subset; the order never changes. Every pass
reads the previous pass's texture and writes a new one (ping-pong between two
render targets; never read and write the same texture).

### 6.1 P0 — Capture

**iOS.** `AVCaptureVideoDataOutput` delivers `CVPixelBuffer` in
`kCVPixelFormatType_32BGRA`. Wrap it with `CVMetalTextureCacheCreateTextureFromImage`.
**No `CIContext.render`, no `CVPixelBufferCreate` in the frame path** — that
allocation is the iOS lag source identified in §1.6.

**Android.** `CameraEffect` hands a `SurfaceRequest`; create a `SurfaceTexture`
bound to a `GL_TEXTURE_EXTERNAL_OES` texture. Sample with
`#extension GL_OES_EGL_image_external_essl3 : require` and
`samplerExternalOES`. Apply the texture transform matrix from
`SurfaceTexture.getTransformMatrix` — do not assume identity.

The tracker gets a **separate, downscaled** copy (§11.2), produced on the GPU
by a blit, not on the CPU.

### 6.2 P1 — Beauty (skin smoothing)

Edge-preserving smoothing, masked to skin. Three steps:

```
1. Downsample source to ¼ resolution.
2. Separable Gaussian blur, radius = 0.045 × interocularPx  [CALIBRATE]
3. Recombine at full resolution:
     detail = source − blurredUp
     // suppress small detail (pores, blemishes), keep large (edges, features)
     keep   = smoothstep(threshold, threshold × 2.5, abs(detail))
     smooth = blurredUp + detail × keep
     out    = mix(source, smooth, strength × skinMask)
```

`threshold` = 0.06 in linear luma `[CALIBRATE]`.

`skinMask` comes from rendering the face mesh into a single-channel target with
a 6 px feathered edge, **minus** the eye and lip contours (Appendix A gives the
index loops) so eyelashes and lip edges stay sharp. Without that subtraction
the effect reads as a smear, which is the classic "cheap beauty filter" look.

Run at half resolution on tier B and below.

### 6.3 P2 — Colour

64³ LUT stored as a 512×512 strip (8×8 tiles of 64×64) — one PNG, identical
bytes on both platforms, so grades cannot drift.

```glsl
vec3 lut(sampler2D strip, vec3 c) {
    c = clamp(c, 0.0, 1.0);
    float b  = c.b * 63.0;
    float b0 = floor(b), b1 = min(b0 + 1.0, 63.0);
    vec2 uv0 = vec2(mod(b0, 8.0) * 64.0 + c.r * 63.0 + 0.5,
                    floor(b0 / 8.0) * 64.0 + c.g * 63.0 + 0.5) / 512.0;
    vec2 uv1 = vec2(mod(b1, 8.0) * 64.0 + c.r * 63.0 + 0.5,
                    floor(b1 / 8.0) * 64.0 + c.g * 63.0 + 0.5) / 512.0;
    return mix(texture(strip, uv0).rgb, texture(strip, uv1).rgb, b - b0);
}
```

Then saturation and contrast in linear space. `GL_CLAMP_TO_EDGE` and `GL_LINEAR`
on the strip; sampling across tile boundaries is the classic banding bug and the
`+0.5` texel centring above is what prevents it.

### 6.4 P3 — Warp

A screen-space displacement field, evaluated per pixel. Each warp control
projects its anchor to screen space and applies a radial falloff.

```glsl
vec2 warpUV(vec2 uv) {
    vec2 p = uv * uResolution;
    for (int i = 0; i < uWarpCount; ++i) {
        vec2  c = uWarpCenter[i];              // px, projected anchor
        float r = uWarpRadius[i];              // px, radiusCm × cmToPx
        vec2  v = p - c;
        float d = length(v) / r;
        if (d >= 1.0) continue;
        float f = 1.0 - d;
        f = f * f * (3.0 - 2.0 * f);           // smoothstep falloff

        if (uWarpMode[i] == MAGNIFY) {
            // sample nearer the centre ⇒ region appears larger
            p = c + v * (1.0 - uWarpStrength[i] * f);
        } else if (uWarpMode[i] == PINCH) {
            p = c + v * (1.0 + uWarpStrength[i] * f);
        } else {                                // TRANSLATE
            p += uWarpDir[i] * uWarpStrength[i] * r * f;
        }
    }
    return p / uResolution;
}
```

`cmToPx` is derived per frame from the projected inter-ocular distance, so
warps scale correctly as the user moves toward or away from the camera.

**Critical consistency rule.** Later passes draw onto an image that has been
warped. Any anchor used by P4–P7 must be pushed through the *inverse* of the
same field before projection, or props will slide off warped features. Because
the field is not analytically invertible, use **three Newton iterations**:

```
q = p
repeat 3×:  q = q − (warp(q) − p)
```

Three iterations converge to sub-pixel for our strength range. Implement this
once, in `FaceGeometry`, and call it from every pass. It is the most commonly
missed detail in a warp pipeline.

### 6.5 P4 — Face texture

Draw the 478-vertex mesh with its canonical UVs, sampling the atlas. This is
makeup, tiger stripes, blush, freckles — anything that must live *on* the skin
and deform with expression.

- Vertex positions: project `vertices[i]` through `P · headMatrix`, then apply
  §6.4's inverse warp.
- UVs: fixed, from `canonical/face_model.json`. Never computed at runtime.
- Triangles: fixed index buffer, uploaded once at init.
- Blend modes per §5.5; `multiply` for stripes and shadow, `screen` for glow,
  `normal` for opaque paint.
- Fade opacity by `1 − smoothstep(0.55, 0.85, |yaw|)` so textures on the far
  cheek do not smear as the head turns past ~35°.

### 6.6 P5 — Occluder depth prepass

**This pass is what produces depth perception.** It writes nothing visible.

```
colorMask(false, false, false, false)
depthMask(true); depthFunc(LESS); enable(DEPTH_TEST)
draw faceMesh          (478 verts, canonical topology)
draw skullProxy        (low-poly hemisphere, fitted — see below)
colorMask(true, true, true, true)
```

The face mesh alone covers only the front of the face. A hat or hairband needs
the *back* of the head to occlude it. Fit a 96-triangle hemisphere to the mesh
once at init: centre = centroid of indices `{10, 152, 234, 454}`, radius =
`0.62 × |v[234] − v[454]|` `[CALIBRATE]`, oriented by `headMatrix`.

Inflate the occluder along its normals by **1.5 mm** to avoid z-fighting where
props rest against skin.

### 6.7 P6 — Props

The pass that replaces all the Bézier art. Each layer is a textured quad placed
in canonical space:

```
// 1. resolve anchor in canonical space (centimetres)
anchorCm = Σ(w_i · vertices[idx_i]) + offsetCm

// 2. apply bindings (blendshapes) and physics (spring)
scale   = sizeCm  · Π(scaleBindings)
opacity = Π(opacityBindings)
rotZ    = rotationDeg.z + springAngle

// 3. build the quad's four corners IN CANONICAL SPACE
//    → rotation with the head is automatic, because headMatrix comes next
corners = quadCorners(anchorCm, scale, rotationDeg + rotZ, billboard)

// 4. project
clip = P · headMatrix · vec4(corner, 1.0)

// 5. rasterise with depth test against P5's buffer
```

Steps 3 and 4 in that order are the entire difference between this spec and the
current code. Building the quad in head space and projecting it afterwards
gives correct perspective, correct foreshortening, correct occlusion and
correct parallax, with no `tan(yaw * 0.18)` shear anywhere.

- `billboard: "none"` — fully head-locked (ears, horns, glasses).
- `billboard: "y"` — yaw-locked to camera, pitch follows head (halo).
- `billboard: "full"` — always faces camera (2D badges, sparkles).
- Sort by `order`, then by projected depth. Alpha-blend premultiplied.
- Batch every layer of a filter into **one** draw call with a shared vertex
  buffer and per-instance attributes. 12 props must not be 12 draws.

**Spring physics.** Port the existing `SpringState`
(`ClipFaceEffects.swift:141-151`) — it is correct. Drive it with head roll
velocity for ear/hair bounce:

```
target = −headRollVelocity · 0.08
angle  = spring.update(target, dt)        // stiffness 160, damping 12
angle  = clamp(angle, −maxDeg, +maxDeg)
```

### 6.8 P7 — Ambient

CPU-simulated particles (≤120 live), one instanced draw call. Emission is
triggered by blendshape thresholds per §5.5. Depth-tested against P5 so
confetti passes behind the head. Simulation is fixed-step at 60 Hz with an
accumulator, so behaviour does not change with frame rate.

---

## 7. iOS implementation

### 7.1 Adding MediaPipe — no CocoaPods

**The repo has no Podfile.** Dependencies are SPM plus vendored xcframeworks
(`apps/ios/vendor/WebRTC.xcframework`, `apps/ios/vendor/firebase-ios-sdk`), and
`FRAMEWORK_SEARCH_PATHS` already contains `$(PROJECT_DIR)/../vendor`
(`project.pbxproj:562-565`). MediaPipe ships only as a CocoaPod, so:

1. In a scratch directory, `pod install` a throwaway project depending on
   `MediaPipeTasksVision` (pin the version; record it in this file).
2. Copy `MediaPipeTasksVision.xcframework` from `Pods/` into `apps/ios/vendor/`.
3. Add it to the Voiid target's **Frameworks, Libraries, and Embedded Content**
   as *Embed & Sign*. No search-path change is needed.
4. Commit the xcframework, matching how `WebRTC.xcframework` is handled.
5. Record the pinned version and the extraction steps in
   `apps/ios/vendor/README.md`.

> **Known hazard.** This repo has previously hit `xcodebuild` hangs during SPM
> resolution, fixed by vendoring a package locally. Vendoring here is
> consistent with that fix and deliberately avoids adding a remote package.

Add `face_landmarker.task` to the app bundle as a resource (do **not** put it
in an asset catalog — it must be readable as a file path).

### 7.2 Tracker

```swift
let options = FaceLandmarkerOptions()
options.baseOptions.modelAssetPath = Bundle.main.path(
    forResource: "face_landmarker", ofType: "task")!
options.baseOptions.delegate = .GPU
options.runningMode = .liveStream
options.numFaces = 1
options.outputFaceBlendshapes = true
options.outputFacialTransformationMatrixes = true      // required for §5.2
options.faceLandmarkerLiveStreamDelegate = self
```

Feed with `detectAsync(image:timestampInMilliseconds:)`. Timestamps must be
**strictly monotonically increasing** or MediaPipe throws; derive them from the
sample buffer's presentation time and drop any frame whose timestamp does not
advance.

### 7.3 Rendering

Keep the existing `MTKView` + `ClipCameraRenderer` structure — it is sound. Replace
the CoreImage body of `draw(in:)` with `FXRenderer.render(...)`.

- One `MTLRenderPipelineState` **per pass**, built once at init and cached.
  Building a pipeline state mid-frame is a multi-millisecond stall.
- One depth texture (`.depth32Float`) shared by P5–P7.
- Two ping-pong colour textures at render resolution, `.bgra8Unorm`, private
  storage.
- `MTLTexture` from the camera via `CVMetalTextureCache`; hold the
  `CVMetalTexture` until the command buffer completes or the texture is freed
  under you.
- Triple-buffer uniforms with a `DispatchSemaphore(value: 3)`.

For recording, `writeFrame` composites into the `AVAssetWriterInputPixelBufferAdaptor`
buffer. Replace `writerCIContext.render` with a Metal blit from the same output
texture the preview used — same pixels, one render, no second pass.

---

## 8. Android implementation

### 8.1 CameraX must go to 1.4.x

`libs.versions.toml:38` pins `camerax = "1.3.4"`. `CameraEffect` with a
`VIDEO_CAPTURE` target — the mechanism that puts the filter into the recording
— requires **1.4.0 or later**. Bump it.

```toml
camerax = "1.4.1"    # CameraEffect(PREVIEW | VIDEO_CAPTURE) — required for face FX
mediapipeTasksVision = "0.10.14"    # verify latest at implementation time
```

```kotlin
implementation(libs.mediapipe.tasks.vision)
```

Remove the ML Kit face-detection dependency added in the current working tree
(`build.gradle.kts`, `libs.versions.toml`) — MediaPipe replaces it. Verified at
the time of writing: `grep -rn mlkit apps/android/app/src/main/java/` matches
**only** `ClipFaceEffects.kt`, so the dependency can be deleted outright along
with that file. Re-run the grep before deleting in case that has changed.

> **Regression surface.** CameraX is shared with the stories camera. The
> upgrade needs a pass over every `bindToLifecycle` call site. This is called
> out as its own phase (§13 Phase 5) with its own test matrix, because it is
> the riskiest change in this document and it is *not* optional — without it,
> Android filters can never reach the file (§1.5).

### 8.2 The effect

```kotlin
class FaceFxEffect(
    private val engine: FaceFxEngine,
    executor: Executor,
) : CameraEffect(
    PREVIEW or VIDEO_CAPTURE,
    executor,
    FaceFxSurfaceProcessor(engine),
    { t -> Log.e("FaceFx", "effect error", t) }
)
```

`FaceFxSurfaceProcessor` implements `SurfaceProcessor`:

- `onInputSurface(request)` — create a `SurfaceTexture` on the GL thread, bind
  it to an external OES texture, hand back its `Surface`.
- `onOutputSurface(output)` — create an `EGLSurface` per output. **There will
  be two**, preview and video, possibly at different resolutions and rotations.
  Render the same engine output into each with the transform
  `output.updateTransformMatrix` provides.

Attach via `UseCaseGroup.Builder().addEffect(faceFxEffect)`.

Then **delete** the Compose `Canvas` overlay at `ClipCameraView.kt:521-540` and
the DISPLAY-ONLY comment block at `ClipCameraView.kt:304-316`. The colour
filter's `ColorMatrixColorFilter`-on-TextureView trick stays as it is — it is
correct, deliberate, and re-applied at export by `Transformer`.

### 8.3 Tracker

```kotlin
val options = FaceLandmarker.FaceLandmarkerOptions.builder()
    .setBaseOptions(BaseOptions.builder()
        .setModelAssetPath("facefx/face_landmarker.task")
        .setDelegate(Delegate.GPU)
        .build())
    .setRunningMode(RunningMode.LIVE_STREAM)
    .setNumFaces(1)
    .setOutputFaceBlendshapes(true)
    .setOutputFacialTransformationMatrixes(true)
    .setResultListener(::onResult)
    .setErrorListener(::onError)
    .build()
```

**GPU delegate fallback.** On some OEM drivers the GPU delegate fails to
initialise. Catch it, fall back to `Delegate.CPU`, and force device tier C.
Log which path was taken — this will be the top support question.

Model in `app/src/main/assets/facefx/`. `aaptOptions { noCompress += "task" }`
so it can be memory-mapped rather than unzipped at load.

### 8.4 GL notes

- Context: OpenGL ES 3.0, one shared context on a dedicated `HandlerThread`.
- Shaders in `assets/facefx/shaders/`, compiled once at init, `glProgram`
  objects cached by pass.
- External textures need `GL_OES_EGL_image_external_essl3`; you cannot use
  `samplerExternalOES` in a pass that also samples a normal `sampler2D` on some
  drivers — blit OES → 2D once in P0 and sample normally thereafter.
- No `glFinish()` in the frame path.
- Release every FBO and texture in `onDispose`; CameraX will recreate the
  processor on rotation.

---

## 9. The 20 launch filters

Bundled filters ship in the binary; CDN filters download on first tap (§10).

### Props — 12 (CDN, except `shades` which is bundled)

| # | id | Name | Layers | Key bindings |
|---|---|---|---|---|
| 1 | `puppy` | Puppy | ears ×2, snout, tongue | `jawOpen` → tongue opacity + `scale.y`; ear spring on roll |
| 2 | `cat` | Cat | ears ×2, nose, whiskers (face texture) | `mouthSmileLeft/Right` → whisker spread |
| 3 | `bunny` | Bunny | ears ×2, nose, teeth | `jawOpen` → teeth; long-ear spring, `maxDeg` 26 |
| 4 | `koala` | Koala | ears ×2, snout | ear spring, low stiffness (120) |
| 5 | `tiger` | Wildcat | ears ×2, stripes (face texture), fangs | `jawOpen` → fangs `scale.y` |
| 6 | `bear` | Bear | ears ×2, snout, cheeks | `cheekPuff` → cheek scale |
| 7 | `shades` | Shades | frame, lens L, lens R | none — **occlusion is the whole effect** (arms pass behind cheeks) |
| 8 | `visor` | Cyber Visor | visor, HUD glow, scanline | `eyeBlinkLeft` → HUD flicker |
| 9 | `crown` | Crown | crown, gems ×3 | slight `billboard: y`; pitch-aware seating |
| 10 | `halo` | Halo | ring, rim glow | `billboard: y`; 0.25 Hz bob; additive blend |
| 11 | `devil` | Devil | horns ×2, eye glow | `browDownLeft/Right` → glow intensity |
| 12 | `party` | Party | hat, confetti (particles) | `jawOpen > 0.45` **or** `mouthSmile > 0.6` → burst |

### Beauty — 4 (bundled; shader-only, ~0 MB besides two small LUT PNGs)

| # | id | Name | Configuration |
|---|---|---|---|
| 13 | `smooth` | Smooth | P1 `smooth 0.45`, `brighten 0.04` |
| 14 | `glow` | Glow | P1 `smooth 0.30` + bloom on skin mask, warm lift |
| 15 | `vivid` | Vivid | P2 `vivid.png`, saturation 1.18, contrast 1.08 |
| 16 | `film` | Film | P2 `film.png` + grain + halation |

### Warp — 4 (bundled; shader-only, 0 MB)

| # | id | Name | Warp controls |
|---|---|---|---|
| 17 | `bigeyes` | Big Eyes | 2× magnify at eye centres, `r` 2.2 cm, `s` 0.28 |
| 18 | `slimface` | Slim Face | 2× translate inward at jaw `{172, 397}`, `r` 3.5 cm, `s` 0.18 |
| 19 | `chipmunk` | Chipmunk | 2× magnify at cheeks `{50, 280}`, `r` 2.8 cm, `s` 0.22 |
| 20 | `alien` | Alien | magnify at forehead `{10}` + pinch at chin `{152}` |

**Bundled set (9):** all 8 shader-only filters (`smooth`, `glow`, `vivid`,
`film`, `bigeyes`, `slimface`, `chipmunk`, `alien`) plus `shades`. Shader-only
filters carry no atlas, so bundling them costs nothing but guarantees the rail
is never empty offline — and this set is exactly what a tier-C device can run
(§11.2), so the cheapest phones get a complete, working filter rail with no
download at all. `shades` is bundled as the one offline prop.

**CDN set (11):** the remaining props — `puppy`, `cat`, `bunny`, `koala`,
`tiger`, `bear`, `visor`, `crown`, `halo`, `devil`, `party`.

All 20 warp/beauty strengths are `[CALIBRATE]` — tune on real faces, not
synthetic ones, across at least four skin tones (§12.4).

---

## 10. Asset pipeline and delivery

### 10.1 Pack format

`<id>.voiidfx` — a zip, stored (not deflated), containing:

```
manifest.json        // §5.5
atlas.webp           // premultiplied alpha, ≤2048², power-of-two
lut.png              // optional, 512×512
```

Target ≤400 KB per pack; `pack.mjs` fails the build above 600 KB.

### 10.2 CDN

```
https://cdn.voiid.app/fx/v1/index.json
https://cdn.voiid.app/fx/v1/<id>/<version>.voiidfx
```

`index.json` lists every filter with `id`, `version`, `bytes`, `sha256`,
`minTier`, `minAppVersion`. Fetched on Clips-camera open, cached 6 h.

**Security and integrity:**
- HTTPS only; reuse the app's existing pinning configuration.
- **Verify the SHA-256 against `index.json` before unpacking.** A pack that
  fails is deleted and reported, never used.
- Unzip with a path-traversal guard: reject any entry whose name contains `..`
  or a leading `/`, and reject entries not in the three-file whitelist above.
- Cap decompressed size at 4 MB per pack (zip-bomb guard).

**Cache:** app cache directory, LRU, 40 MB cap, evicted by last-used. Bundled
filters are never evicted. Cache key is `<id>@<version>`, so a version bump
downloads cleanly rather than mutating in place.

**UI states** for CDN filters — specify all four, do not leave them to the
implementer: `not-downloaded` (badge on the tile), `downloading`
(determinate ring), `ready`, `failed` (retry affordance, one tap). Tapping an
undownloaded filter starts the download and applies it automatically on
completion **only if** the tile is still selected.

### 10.3 Authoring

Artists work in `packages/facefx/art/` and export to the atlas via
`build/pack.mjs`. The canonical face model with its UV layout is exported to
`packages/facefx/canonical/face_model.json` and to a PNG UV template for
painting face textures. Anchors are chosen by index against that template.

`npm run facefx:validate` runs §5.5's validation over every manifest and is
wired into CI alongside the existing `tools/check-*.py` scripts.

---

## 11. Performance

### 11.1 Budget

At 30 fps the frame budget is 33.3 ms. The filter stack gets **≤8 ms GPU** at
1080p on tier A. Per pass:

| Pass | Budget | Notes |
|---|---|---|
| P0 capture | 0.3 ms | zero-copy; a blit at most |
| P1 beauty | 2.5 ms | ¼-res blur is most of it |
| P2 colour | 0.4 ms | one LUT fetch pair |
| P3 warp | 0.8 ms | dependent texture read |
| P4 face tex | 0.6 ms | 478 verts, ~900 tris |
| P5 occluder | 0.3 ms | depth only, no fragment work |
| P6 props | 1.5 ms | **one** instanced draw |
| P7 ambient | 0.6 ms | ≤120 particles, instanced |
| **Total** | **7.0 ms** | 1 ms headroom |

Tracker inference is off the render thread and does not count against this, but
must stay under **12 ms** or it cannot hold 24 Hz alongside rendering.

### 11.2 Tiers

| Tier | Render | Tracker | Passes |
|---|---|---|---|
| A | 1080p | 30 Hz, 256² input | all |
| B | 1080p | 24 Hz, 192² input | P1 at ½ res |
| C | 720p | 15 Hz + extrapolation, 192² input | shader-only filters; props capped at 4 layers; no P7 |

**Assign by measurement, not by model name.** On first Clips-camera open, run a
2-second calibration rendering the heaviest pass chain at the target
resolution, take the median GPU frame time, and assign: `<6 ms → A`,
`<11 ms → B`, else `C`. Persist the result; re-measure on OS upgrade.

**Dynamic downgrade.** If the rolling 3-second mean exceeds 28 ms, drop one
tier and log it. If `thermalState` reaches `.serious` (iOS) or
`PowerManager.getCurrentThermalStatus() >= THERMAL_STATUS_MODERATE` (Android),
drop to C regardless of measurement. **Never upgrade mid-session** — oscillating
between tiers is worse than sitting at the lower one.

Filters whose `tier` exceeds the device tier are shown in the rail but
visually de-emphasised with a "not supported on this device" note. They are
never silently missing.

### 11.3 Standing rules

- No allocation in the frame path. Pre-allocate every buffer at init.
- No shader compilation, pipeline-state creation, or texture creation after init.
- One instanced draw per pass. Never one draw per layer.
- Never read and write the same texture in a pass. Ping-pong.
- Tracker input is downscaled **on the GPU**. The CPU never touches pixels.
- Release GPU resources when the camera is not visible; a backgrounded Clips
  camera must hold no GPU memory.

---

## 12. Testing and verification

### 12.1 Unit (both platforms, mirrored cases)

- Manifest parse: valid, unknown-schema, out-of-range index, weights ≠ 1,
  `atlasRect` outside atlas, unknown blendshape, duplicate `order`.
- Anchor resolution against a fixed synthetic `FaceFrame` → expected cm, ±0.01.
- Binding evaluation: below/at/inside/above range; multiple bindings on a target.
- One Euro: step input converges; monotonic timestamps; `dt == 0` does not divide by zero.
- Extrapolation: clamps at 50 ms; clamps displacement at `0.15 × interocular`;
  resets on re-acquisition.
- Inverse warp: `warp(inverseWarp(p)) ≈ p` within 0.5 px across the strength range.
- LUT: identity LUT is a no-op within 1/255 on all 8-bit values.

### 12.2 Golden frames

Ten short clips in `packages/facefx/fixtures/` covering: frontal, ±40° yaw,
±25° pitch, fast turn, occluded (hand across face), two faces, low light,
strong backlight, four skin tones, glasses already worn.

Render each through every filter at a fixed timestamp; compare to a golden PNG
with a perceptual metric (max ΔE₀₀ ≤ 2.0 over 99 % of pixels). Goldens are
generated once, reviewed by eye, and committed. **Regenerating a golden requires
a reviewed diff in the PR** — this is the guard that stops quality drifting.

### 12.3 Parity

`tools/check-facefx-parity.py` (CI) asserts:
- both platforms' bundled filter ID lists are identical and ordered identically;
- every manifest in `packages/facefx/manifests/` is referenced by both;
- manifest versions match the packed artefacts;
- the shader pass list and order match between `FaceFX.metal` and
  `assets/facefx/shaders/`.

Plus a runtime parity test: run the same fixture clip through both engines and
require mean ΔE₀₀ ≤ 4.0 between platforms.

### 12.4 Manual matrix

| Axis | Cases |
|---|---|
| Devices | iPhone 12/15/17, Pixel 6a, Samsung A14 (tier C), a 4 GB Xiaomi |
| Lighting | daylight, indoor tungsten, backlit, near-dark |
| Skin tone | ≥4 tones across the Fitzpatrick range — **required, not optional** |
| Faces | glasses, beard, hijab/headwear, long hair over the face, partial occlusion |
| Motion | still, slow turn, fast turn, walking |
| Camera | front, rear, mid-session switch |
| Lifecycle | background/foreground, rotate, call interrupt, low battery, thermal throttle |

### 12.5 Release gates

Do not ship unless **all** hold:

1. Recorded clips on both platforms contain the filter (§1.5 fixed, verified by
   decoding a recording and diffing against the preview).
2. Tier-A GPU frame time ≤ 8 ms at 1080p, measured with Instruments and Perfetto.
3. No allocation in the frame path (Allocations instrument / `atrace` clean).
4. Install-size delta ≤ 4.5 MB per platform.
5. Golden-frame suite green.
6. Parity check green.
7. The manual matrix passes with no P1/P2 defects.

---

## 13. Execution plan

Each phase has an exit criterion that must be demonstrated with real output.

### Phase 0 — Groundwork
Create `packages/facefx/` with the canonical model, schema, `validate.mjs`,
`pack.mjs`, and one hand-written manifest (`shades`). Wire `npm run
facefx:validate` into CI.
**Exit:** `facefx:validate` passes on `shades.json` and fails correctly on each
of the seven invalid fixtures from §12.1.

### Phase 1 — Tracker, both platforms, no rendering
Vendor the xcframework (§7.1); bump CameraX and add MediaPipe on Android
(§8.1). Get `FaceFrame` flowing on both platforms. Draw **only** debug dots for
the 478 landmarks over the camera.
**Exit:** dots track the face on both platforms; tracker inference ≤ 12 ms
measured on a mid device; screenshots from both platforms attached.

### Phase 2 — Projection calibration ⚠️ gate
Implement §5.2 and run the reprojection test.
**Exit:** mean reprojection error < 2 px at 720p on both platforms, with the
final `fovY` recorded in this document. **Do not proceed while this fails** —
every placement downstream is built on it.

### Phase 3 — Stabilisation
One Euro + extrapolation + re-acquisition (§5.4).
**Exit:** side-by-side video of raw vs stabilised landmarks; visible jitter
gone and no perceptible lag on a fast head turn.

### Phase 4 — Renderer skeleton, iOS first
P0, P5, P6 only. `shades` filter end to end, bundled.
**Exit:** glasses sit correctly through ±40° yaw, and **the arms are occluded by
the cheeks**. Video, not a still.

### Phase 5 — Android CameraEffect ⚠️ risk
Port the Phase 4 renderer. This is the CameraX 1.4 upgrade (§8.1); audit every
`bindToLifecycle` call site including the stories camera.
**Exit:** `shades` matches iOS on device, **and a recorded clip contains the
filter**, verified by decoding the file. Stories camera regression-tested.

### Phase 6 — Remaining passes
P1–P4, P7 on both platforms, in that order, keeping the two shader sets
line-for-line parallel.
**Exit:** all four beauty and all four warp filters shipping; per-pass GPU
timings recorded against §11.1's budget.

### Phase 7 — Asset pipeline and CDN
`FXAssetStore` on both platforms, the four UI states, integrity verification,
LRU cache. CDN populated.
**Exit:** a CDN filter downloads, verifies, applies and survives an app
restart; a deliberately corrupted pack is rejected and reported.

### Phase 8 — The remaining 11 props
Art authored, manifests written, tuned on real faces.
**Exit:** all 20 filters pass the golden-frame suite.

### Phase 9 — Tiering and hardening
Calibration, dynamic downgrade, thermal handling, lifecycle.
**Exit:** every §12.5 release gate green; §12.4 matrix complete.

### Phase 10 — Removal
Delete `ClipFaceEffects.swift`, `ClipFaceEffects.kt`, the Compose overlay
(`ClipCameraView.kt:521-540`), the DISPLAY-ONLY comment block
(`ClipCameraView.kt:304-316`), and the ML Kit dependency (§8.1 — verified
exclusive to the deleted file).
**Exit:** `grep -rn "ClipFaceEffect\|ClipFaceRenderer\|ClipFaceDetector" apps/`
and `grep -rn mlkit apps/android/` both return nothing; both apps build clean;
the golden-frame suite is still green after removal.

---

## 14. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| **CameraX 1.4 regresses the stories camera** | high | Phase 5 is isolated and has its own regression matrix. Ship it behind a flag; keep 1.3.4 revertible for one release. |
| MediaPipe GPU delegate fails on an OEM | med | CPU fallback + forced tier C (§8.3). Log the path taken. |
| Reprojection calibration will not converge | high | Phase 2 is a hard gate. Fallback: solve PnP against the canonical model with the 2D landmarks — more code, same output contract, so nothing downstream changes. |
| Vendored xcframework bloats the repo | low | Same pattern as `WebRTC.xcframework`, already accepted here. |
| CDN unavailable at launch | med | The 6 bundled filters make the rail useful offline. CDN failure degrades, never breaks. |
| Art authoring is the long pole | med | Phase 8 is last and parallelisable. The engine ships and is provable with 9 filters. |
| Blendshape names drift between MediaPipe versions | low | Appendix B is pinned; validation rejects unknown names loudly at load, so a version bump fails in CI rather than silently at runtime. |

---

## Appendix A — Canonical landmark indices

Verify every index against `packages/facefx/canonical/face_model.json` during
Phase 1 by rendering labelled dots. **Treat the table below as a starting map,
not as gospel** — confirm visually before any manifest depends on an index.

| Feature | Indices |
|---|---|
| Nose tip | 1 |
| Nose bridge | 168 |
| Nose base | 2 |
| Chin | 152 |
| Forehead centre | 10 |
| Left face edge | 234 |
| Right face edge | 454 |
| Left eye outer / inner | 33 / 133 |
| Right eye outer / inner | 263 / 362 |
| Left iris centre | 468 |
| Right iris centre | 473 |
| Mouth corners | 61 / 291 |
| Upper / lower lip centre | 13 / 14 |
| Left cheek | 50 |
| Right cheek | 280 |
| Left jaw | 172 |
| Right jaw | 397 |
| Left brow | 70, 63, 105, 66, 107 |
| Right brow | 300, 293, 334, 296, 336 |

Eye and lip contour loops (needed for the §6.2 skin-mask subtraction) are
exported to `face_model.json` as named loops rather than listed here, so the
mask and the mesh cannot drift apart.

## Appendix B — Blendshapes

52 coefficients in MediaPipe's fixed order, mirroring ARKit's naming:

```
_neutral, browDownLeft, browDownRight, browInnerUp, browOuterUpLeft,
browOuterUpRight, cheekPuff, cheekSquintLeft, cheekSquintRight, eyeBlinkLeft,
eyeBlinkRight, eyeLookDownLeft, eyeLookDownRight, eyeLookInLeft,
eyeLookInRight, eyeLookOutLeft, eyeLookOutRight, eyeLookUpLeft, eyeLookUpRight,
eyeSquintLeft, eyeSquintRight, eyeWideLeft, eyeWideRight, jawForward, jawLeft,
jawOpen, jawRight, mouthClose, mouthDimpleLeft, mouthDimpleRight,
mouthFrownLeft, mouthFrownRight, mouthFunnel, mouthLeft, mouthLowerDownLeft,
mouthLowerDownRight, mouthPressLeft, mouthPressRight, mouthPucker, mouthRight,
mouthRollLower, mouthRollUpper, mouthShrugLower, mouthShrugUpper,
mouthSmileLeft, mouthSmileRight, mouthStretchLeft, mouthStretchRight,
mouthUpperUpLeft, mouthUpperUpRight, noseSneerLeft, noseSneerRight
```

Manifests reference these **by name**; the loader resolves to an index once and
validates that every name is known (§5.5).

## Appendix C — Old code disposition

| Code | Disposition |
|---|---|
| `OneEuroFilter` (`ClipFaceEffects.swift:152-185`) | **Port verbatim** — correct. |
| `SpringState` (`ClipFaceEffects.swift:141-151`) | **Port verbatim** — correct. |
| Re-acquisition jump detection (`:385-390`) | **Port the logic** into `PoseStabilizer`. |
| `TrackedFace`, `FaceSmoother`, `ClipFaceDetector` | Delete — replaced by `FaceFrame` / `FaceTracker`. |
| All sprite-drawing functions (~1,900 lines across both files) | Delete — replaced by authored atlases. |
| `ClipFaceRenderer` (both platforms) | Delete — replaced by `FXRenderer`. |
| Compose `Canvas` overlay (`ClipCameraView.kt:521-540`) | Delete — replaced by `CameraEffect`. |
| `ColorMatrixColorFilter` preview trick (`ClipCameraView.kt:304-330`) | **Keep** — correct and deliberate; unrelated to face FX. |

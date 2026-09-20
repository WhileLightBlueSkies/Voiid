# Voiid face filter — image generation prompts

19 assets for the 11 filters. Generate one at a time, save with the **exact filename**
given, and send them over. I handle background removal, trimming, packing and placement.

---

## Before you start — read this bit

**Paste this preamble at the START of every single prompt.** It is what keeps 19 separate
images looking like one set instead of a jumble sale:

> Photorealistic 3D render on a fully transparent background. Single isolated object, centred,
> filling about 80% of a square frame. Straight-on front view, orthographic, no perspective
> distortion, no tilt. Key light from the upper left at 45 degrees, soft fill from the right,
> gentle ambient occlusion in the crevices. No cast shadow on any surface. No background,
> no scene, no floor, no person, no animal, no head, no mannequin, no hands, no text,
> no watermark. Crisp edges, high detail, 4K quality.

**Settings:** square, largest size available (1024×1024 or better), PNG.

**Say "transparent background" explicitly** — if the model gives you white or a checkerboard
anyway, send it regardless. I can strip a flat background. I cannot rescue one baked over
the object itself.

**Three failure modes to watch for, and what to do:**

| What you'll see | Why it's a problem | Fix |
|---|---|---|
| It draws the whole dog/cat/person | Most common failure by far | Re-prompt: "object only, floating in empty space, no animal, no head" |
| Object tilted or in 3/4 view | Won't sit straight on a face | Re-prompt: "perfectly straight-on, symmetrical, no rotation" |
| A drop shadow underneath | Baked shadows fight the real one I add | Re-prompt: "no shadow, no reflection, no ground plane" |

**Anything with "_left" in the name: generate ONE ear/horn only, not a pair.** I mirror it in
code. This guarantees a symmetric pair — AI nearly always makes the two sides slightly
different, and on a face that reads as broken.

---

## 1. Puppy

**`dog_ear_left.png`**
> A single floppy dog ear, golden-brown short fur, seen from the front. Broad and rounded
> where it would attach to the skull at the top, tapering to a soft rounded tip at the bottom.
> Slightly curved outward. Visible individual fur strands along the silhouette. The inner ear
> surface is a warmer, paler tan and sits in soft shadow. Ear is upright, hanging downward,
> long axis vertical.

**`dog_nose.png`**
> A dog's nose and muzzle tip, front view. Wet glossy black leather-textured nose with two
> nostrils and a vertical philtrum groove below, surrounded by short pale cream muzzle fur.
> Strong specular highlight on the wet nose surface.

**`dog_tongue.png`**
> A dog's tongue hanging out and downward, front view. Soft wet pink flesh, slightly darker
> toward the back, glossy specular highlights, a subtle central groove down the middle,
> rounded tip, slight translucency at the thin edges. Tongue only, no mouth, no teeth, no jaw.

---

## 2. Wildcat

**`tiger_ear_left.png`**
> A single tiger ear, front view, upright and rounded-triangular. Orange-and-black striped
> outer fur, a ring of long white fur inside the rim, soft pink inner ear surface at the
> centre. Two short black stripe markings on the outer surface. Tufts of white fur along the
> inner edge.

**`tiger_nose.png`**
> A big cat's nose, front view. Broad pink-brown leathery nose pad with a rounded triangular
> shape, visible nostril slits, a vertical groove below, surrounded by short orange and white
> fur with fine black stripe markings.

**`tiger_stripes.png`**
> Black tiger stripe markings and white muzzle fur arranged as a symmetrical face pattern,
> laid out flat and facing forward, with a large empty transparent gap in the centre where a
> nose would be and two empty transparent gaps where eyes would be. Markings only — no skin,
> no face, no head beneath them.

---

## 3. Party

**`party_hat.png`**
> A glossy cone-shaped party hat standing upright, point at the top. Bright yellow with
> diagonal red, cyan and purple metallic foil stripes wrapping around the cone. A fluffy red
> pom-pom on the very top. Slight sheen on the foil, subtle paper texture, crisp circular
> base rim at the bottom.

---

## 4. Cyber

**`cyber_visor.png`**
> A futuristic cyberpunk visor, front view, wide and horizontal, wrapping slightly. Dark
> smoked glass with a glowing cyan edge strip along the top and bottom, faint horizontal
> scanlines across the glass, a small magenta targeting reticle glowing on the right lens
> area, brushed dark metal frame. Neon reflections on the glass surface.

---

## 5. Bunny

**`bunny_ear_left.png`**
> A single rabbit ear, front view, long, tall and upright, narrow, with a gently rounded tip.
> Soft white fur on the outside with fine visible strands, a long soft pink inner ear channel
> running most of its length. Slight translucency where light passes through the thin ear.

**`bunny_nose.png`**
> A rabbit's nose, front view. Small soft pink triangular nose with a vertical split below it,
> surrounded by fine white fur and a few fine whiskers.

---

## 6. Koala

**`koala_ear_left.png`**
> A single koala ear, front view, large and round, extremely fluffy, with long soft grey fur
> sticking out in all directions around the rim. Soft pale pink and white fur inside the round
> centre. Very soft and dense fur texture.

**`koala_nose.png`**
> A koala's nose, front view. Large broad oval dark charcoal-grey leathery nose, taller than
> it is wide, with a soft matte-to-glossy surface, subtle skin texture and a soft highlight on
> the upper left, surrounded by short grey fur.

---

## 7. Cat

**`cat_ear_left.png`**
> A single cat ear, front view, upright and pointed triangular with a gently curved outer edge.
> Dark charcoal-grey short fur outside with visible fine strands along the silhouette, a soft
> warm pink inner ear surface, and pale white tufts of fur spilling out from inside the ear
> along the rim.

**`cat_nose.png`**
> A cat's nose, front view. Small pink inverted-triangle leather nose pad with a soft matte
> surface, small nostril slits and a vertical groove below, surrounded by very short grey fur.

**`cat_whiskers.png`**
> Long fine white cat whiskers arranged symmetrically, fanning out to the left and right, with
> a large empty transparent gap in the centre. Whiskers only — thin, tapering, slightly curved,
> catching a soft highlight. No face, no muzzle, no skin behind them.

---

## 8. Shades

**`sunglasses.png`**
> A pair of stylish sunglasses, front view, perfectly straight on and symmetrical. Glossy black
> acetate frame, dark blue-tinted gradient lenses with a realistic reflection streak across
> each lens, a visible nose bridge between the lenses, small metal hinge details at the outer
> corners. Folded arms not visible.

---

## 9. Crown

**`crown.png`**
> An ornate royal gold crown, front view, straight on and symmetrical, with five tall pointed
> peaks — the centre peak tallest. Polished yellow gold with bright specular highlights and
> darker recesses, fine engraved detailing on the wide band at the base, and faceted deep red
> ruby cabochons set at the tip of each peak and at the centre of the band. Realistic metal
> reflections, sharp facet edges on the gems.

---

## 10. Halo

**`halo.png`**
> A glowing golden halo ring, seen at a shallow angle from slightly below so it reads as a
> horizontal ellipse rather than a circle. Radiant warm gold with a soft luminous bloom around
> it, brighter on the upper edge, semi-translucent, ethereal. Ring only, nothing inside it.

---

## 11. Devil

**`devil_horn_left.png`**
> A single devil horn, front view, curving upward and outward to a sharp point. Deep glossy
> red with darker crimson shading in the grooves and a brighter orange-red ridge along the
> front edge, subtle horizontal ridge texture like a real horn, sharp tip. Base is wide where
> it would emerge from the skull.

---

## When you've got them

Send them across however's easiest. Then I will:

1. Strip backgrounds if they aren't already transparent, and trim to content.
2. Downscale to two resolutions and drop them into `apps/android/app/src/main/assets/filters/`.
3. Switch the renderer from drawing vector paths to drawing bitmaps — the placement maths
   (`crownRise`, `headSpan`, the nose spans) is unchanged, so the work from today carries over.
4. Put a build on your phone.

**Priority if you don't want to do all 19 at once:** `dog_ear_left`, `crown`, `cat_ear_left`.
Those three cover fur, metal and a clean graphic shape — enough to prove the pipeline before
you spend time on the rest.

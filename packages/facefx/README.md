# @voiid/facefx

Shared face-filter definitions for iOS and Android. **This is the single source
of truth** — no filter behaviour may live in platform code.

```
canonical/face_model.json   468 verts, UVs, 898 tris, named anchors + loops
manifests/<id>.json         one per filter, authored (sprite NAMES, cm units)
art/<id>/*.svg              authored art, resolution-independent
luts/*.cube                 colour grades
build/                      canonical builder, validator, packer
dist/                       generated .voiidfx packs (gitignored)
```

## Commands

```bash
npm test -w @voiid/facefx        # validate manifests + validator self-test
python3 build/pack.py            # build every .voiidfx pack
python3 build/pack.py shades     # build one
```

## Authoring a filter

1. Draw sprites as SVG into `art/<id>/`. Author large (~4× on-device); the
   packer rasterises to whatever a device tier needs.
2. Write `manifests/<id>.json`. Reference sprites **by name**, place them in
   **centimetres** against the canonical face model.
3. `npm test -w @voiid/facefx` then `python3 build/pack.py <id>`.

Geometry is centimetres in canonical-model space (face is ~15.3 cm wide,
interocular 8.89 cm). Offsets are applied *before* the head matrix, so a prop
rotates with the head for free.

Never hand-write `atlasRect` — the packer fills it in. The validator rejects
source manifests that try.

## Regenerating the canonical model

```bash
curl -sSO https://raw.githubusercontent.com/google-ai-edge/mediapipe/master/\
mediapipe/modules/face_geometry/data/canonical_face_model.obj
python3 build/build_canonical.py canonical_face_model.obj
```

Landmarks 468–477 are iris points with no mesh position: anchorable, never
rendered as geometry. The renderable mesh is **468** vertices.

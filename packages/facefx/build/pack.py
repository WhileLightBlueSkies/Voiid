#!/usr/bin/env python3
"""Build .voiidfx packs from authored SVG art + source manifests.

  SVG (authored)  -> rsvg-convert -> PNG -> shelf-pack atlas -> cwebp -> .voiidfx

Source manifests reference sprites BY NAME. This resolves each name to a pixel
rect in the packed atlas and writes the resolved manifest into the pack, so an
artist never hand-maintains pixel coordinates.

  python3 packages/facefx/build/pack.py [--scale 1.0] [id ...]
"""
import argparse, json, pathlib, shutil, subprocess, sys, zipfile
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[1]
ART, MANIFESTS, DIST = ROOT / "art", ROOT / "manifests", ROOT / "dist"
PAD = 2               # transparent gutter, stops bilinear bleed between sprites
EXTRUDE = 1           # edge-pixel extrusion into the gutter
MAX_ATLAS = 2048
FAIL_BYTES = 600 * 1024


def need(tool):
    if not shutil.which(tool):
        sys.exit(f"error: '{tool}' not found. brew install librsvg webp")
    return tool


def rasterize(svg: pathlib.Path, scale: float) -> Image.Image:
    with open(svg) as fh:
        head = fh.read(400)
    import re
    w = float(re.search(r'width="(\d+(?:\.\d+)?)"', head).group(1))
    h = float(re.search(r'height="(\d+(?:\.\d+)?)"', head).group(1))
    tw, th = max(1, round(w * scale)), max(1, round(h * scale))
    out = subprocess.run(
        [need("rsvg-convert"), "-w", str(tw), "-h", str(th), "-f", "png", str(svg)],
        capture_output=True, check=True).stdout
    import io
    return Image.open(io.BytesIO(out)).convert("RGBA")


def extrude(atlas: Image.Image, x: int, y: int, w: int, h: int, n: int):
    """Repeat the sprite's border pixels outward so linear sampling at a UV
    edge never picks up a neighbouring sprite or transparent black."""
    px = atlas.load()
    W, H = atlas.width, atlas.height
    for i in range(1, n + 1):
        for cx in range(x, x + w):
            if y - i >= 0:
                px[cx, y - i] = px[cx, y]
            if y + h - 1 + i < H:
                px[cx, y + h - 1 + i] = px[cx, y + h - 1]
        for cy in range(max(0, y - n), min(H, y + h + n)):
            sy = max(y, min(y + h - 1, cy))
            if x - i >= 0:
                px[x - i, cy] = px[x, sy]
            if x + w - 1 + i < W:
                px[x + w - 1 + i, cy] = px[x + w - 1, sy]


def _shelf(sprites, width):
    """Lay sprites out in rows of the given width, tallest first."""
    order = sorted(sprites.items(), key=lambda kv: (-kv[1].height, kv[0]))
    rects, x, y, shelf_h = {}, 0, 0, 0
    for name, im in order:
        w, h = im.width, im.height
        if w > width:
            return None
        if x + w > width:
            x, y, shelf_h = 0, y + shelf_h + PAD, 0
        rects[name] = (x, y, w, h)
        x += w + PAD
        shelf_h = max(shelf_h, h)
    return rects, y + shelf_h


def _pow2_at_least(n):
    p = 1
    while p < n:
        p *= 2
    return p


def shelf_pack(sprites):
    """Try every power-of-two width and keep the layout with the smallest
    atlas AREA -- packing at MAX_ATLAS width wastes GPU memory even when the
    compressed file is small. Deterministic, which golden-frame tests need."""
    best = None
    w = 64
    while w <= MAX_ATLAS:
        got = _shelf(sprites, w)
        if got:
            rects, used_h = got
            used_w = max(r[0] + r[2] for r in rects.values())
            aw, ah = _pow2_at_least(used_w), _pow2_at_least(used_h)
            if ah <= MAX_ATLAS and (best is None or aw * ah < best[1] * best[2]):
                best = (rects, aw, ah)
        w *= 2
    if best is None:
        sys.exit("atlas: a sprite is larger than the maximum atlas size")
    return best


def resolve_sprites(node, rects, sprite_of):
    """Walk the manifest replacing every {"sprite": name} with atlasRect."""
    if isinstance(node, dict):
        if "sprite" in node:
            name = node.pop("sprite")
            if name not in rects:
                raise KeyError(name)
            node["atlasRect"] = list(rects[name])
            sprite_of.add(name)
        for v in node.values():
            resolve_sprites(v, rects, sprite_of)
    elif isinstance(node, list):
        for v in node:
            resolve_sprites(v, rects, sprite_of)


def build(fid: str, scale: float) -> dict:
    manifest = json.loads((MANIFESTS / f"{fid}.json").read_text())
    art_dir = ART / fid
    svgs = sorted(art_dir.glob("*.svg")) if art_dir.is_dir() else []

    DIST.mkdir(exist_ok=True)
    pack_path = DIST / f"{fid}.voiidfx"

    if not svgs:
        # Shader-only filter: no atlas, manifest travels alone.
        manifest.pop("atlas", None)
        with zipfile.ZipFile(pack_path, "w", zipfile.ZIP_STORED) as z:
            z.writestr("manifest.json", json.dumps(manifest, separators=(",", ":")))
        return {"id": fid, "atlas": None, "bytes": pack_path.stat().st_size, "sprites": 0}

    sprites = {s.stem: rasterize(s, scale) for s in svgs}
    rects, aw, ah = shelf_pack(sprites)
    if ah > MAX_ATLAS:
        sys.exit(f"{fid}: atlas {aw}x{ah} exceeds {MAX_ATLAS}")

    atlas = Image.new("RGBA", (aw, ah), (0, 0, 0, 0))
    for name, (x, y, w, h) in rects.items():
        atlas.paste(sprites[name], (x, y))
    for name, (x, y, w, h) in rects.items():
        extrude(atlas, x, y, w, h, EXTRUDE)

    used = set()
    try:
        resolve_sprites(manifest, rects, used)
    except KeyError as e:
        sys.exit(f"{fid}: manifest references sprite {e} with no art/{fid}/{e.args[0]}.svg")
    unused = set(rects) - used
    if unused:
        print(f"  warn {fid}: art not referenced by manifest: {', '.join(sorted(unused))}")

    manifest["atlas"] = "atlas.webp"
    manifest["atlasSize"] = [aw, ah]

    png = DIST / f".{fid}.atlas.png"
    atlas.save(png)
    webp = DIST / f".{fid}.atlas.webp"
    subprocess.run([need("cwebp"), "-quiet", "-q", "92", "-alpha_q", "100",
                    "-exact", str(png), "-o", str(webp)], check=True)

    with zipfile.ZipFile(pack_path, "w", zipfile.ZIP_STORED) as z:
        z.writestr("manifest.json", json.dumps(manifest, separators=(",", ":")))
        z.write(webp, "atlas.webp")
        lut = manifest.get("colour", {}).get("lut")
        if lut:
            z.write(ROOT / "luts" / lut, lut)

    size = pack_path.stat().st_size
    png.unlink(); webp.unlink()
    if size > FAIL_BYTES:
        sys.exit(f"{fid}: pack is {size/1024:.0f} KB, over the {FAIL_BYTES/1024:.0f} KB limit")
    return {"id": fid, "atlas": [aw, ah], "bytes": size, "sprites": len(rects), "rects": rects}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--scale", type=float, default=1.0)
    a = ap.parse_args()

    ids = a.ids or sorted(p.stem for p in MANIFESTS.glob("*.json"))
    sizes, index = {}, []
    for fid in ids:
        r = build(fid, a.scale)
        if r["atlas"]:
            sizes["atlas.webp"] = {"width": r["atlas"][0], "height": r["atlas"][1]}
            sizes[fid] = {"width": r["atlas"][0], "height": r["atlas"][1]}
        m = json.loads((MANIFESTS / f"{fid}.json").read_text())
        index.append({"id": fid, "version": m["version"], "bytes": r["bytes"],
                      "tier": m["tier"], "bundled": m.get("bundled", False)})
        dims = f"{r['atlas'][0]}x{r['atlas'][1]}" if r["atlas"] else "shader-only"
        print(f"ok   {fid:10s} {r['sprites']} sprites  {dims:12s} {r['bytes']/1024:6.1f} KB")

    (ART / "atlas-sizes.json").write_text(json.dumps(sizes, indent=2))
    (DIST / "index.json").write_text(json.dumps({"schema": 1, "filters": index}, indent=2))
    total = sum(i["bytes"] for i in index)
    print(f"\n{len(index)} packs, {total/1024:.1f} KB total")


if __name__ == "__main__":
    main()

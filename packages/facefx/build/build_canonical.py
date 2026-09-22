#!/usr/bin/env python3
"""Turn MediaPipe's canonical_face_model.obj into face_model.json.

The .obj is the ONLY external input to the face FX system. Everything else --
anchors, UVs, the skin mask, the occluder -- is derived from it here, once, so
the two platforms can never disagree about geometry.

Run:  python3 packages/facefx/build/build_canonical.py <path-to.obj>
"""
import json, sys, pathlib

# Named landmark loops. Consecutive pairs MUST be real mesh edges; verified below.
LOOPS = {
    # Subject's left eye (appears right-of-frame in an unmirrored image).
    "eyeLeft": [362, 382, 381, 380, 374, 373, 390, 249,
                263, 466, 388, 387, 386, 385, 384, 398],
    "eyeRight": [33, 7, 163, 144, 145, 153, 154, 155,
                 133, 173, 157, 158, 159, 160, 161, 246],
    "lipsOuter": [61, 146, 91, 181, 84, 17, 314, 405, 321, 375,
                  291, 409, 270, 269, 267, 0, 37, 39, 40, 185],
    "lipsInner": [78, 95, 88, 178, 87, 14, 317, 402, 318, 324,
                  308, 415, 310, 311, 312, 13, 82, 81, 80, 191],
    "faceOval": [10, 338, 297, 332, 284, 251, 389, 356, 454, 323,
                 361, 288, 397, 365, 379, 378, 400, 377, 152, 148,
                 176, 149, 150, 136, 172, 58, 132, 93, 234, 127,
                 162, 21, 54, 103, 67, 109],
}

# Anchors referenced by manifests, by name, so art never hardcodes a raw index.
NAMED = {
    "noseTip": 1, "noseBridge": 168, "noseBase": 2, "chin": 152,
    "foreheadCenter": 10, "faceEdgeLeft": 234, "faceEdgeRight": 454,
    "eyeOuterLeft": 33, "eyeInnerLeft": 133,
    "eyeOuterRight": 263, "eyeInnerRight": 362,
    "mouthCornerLeft": 61, "mouthCornerRight": 291,
    "lipUpperCenter": 13, "lipLowerCenter": 14,
    "cheekLeft": 50, "cheekRight": 280,
    "jawLeft": 172, "jawRight": 397,
    "templeLeft": 127, "templeRight": 356,
    "browLeftInner": 107, "browLeftOuter": 70,
    "browRightInner": 336, "browRightOuter": 300,
}

# Landmarks 468..477 are iris points added by refine_landmarks. They are NOT in
# the canonical mesh and have no UV or topology -- anchors may reference them,
# but they are never rendered as geometry.
IRIS = {"irisCenterLeft": 473, "irisCenterRight": 468}
MESH_VERTEX_COUNT = 468
LANDMARK_COUNT = 478


def parse_obj(path):
    verts, uvs, tris = [], [], []
    for line in pathlib.Path(path).read_text().splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "v":
            verts.append([round(float(x), 6) for x in p[1:4]])
        elif p[0] == "vt":
            uvs.append([round(float(p[1]), 6), round(float(p[2]), 6)])
        elif p[0] == "f":
            # The .obj indexes position and UV separately; MediaPipe's model has
            # one UV per position, so we key on the position index and record the
            # UV against it rather than duplicating vertices.
            corner = []
            for c in p[1:4]:
                bits = c.split("/")
                corner.append((int(bits[0]) - 1, int(bits[1]) - 1 if len(bits) > 1 and bits[1] else None))
            tris.append(corner)
    return verts, uvs, tris


def main():
    src = sys.argv[1]
    verts, raw_uvs, raw_tris = parse_obj(src)
    assert len(verts) == MESH_VERTEX_COUNT, f"expected {MESH_VERTEX_COUNT} verts, got {len(verts)}"

    # Re-key UVs onto position indices.
    uv_by_vertex = [None] * len(verts)
    conflicts = 0
    for corner in raw_tris:
        for vi, ti in corner:
            if ti is None:
                continue
            uv = raw_uvs[ti]
            if uv_by_vertex[vi] is None:
                uv_by_vertex[vi] = uv
            elif uv_by_vertex[vi] != uv:
                conflicts += 1
    missing = [i for i, u in enumerate(uv_by_vertex) if u is None]
    assert not missing, f"vertices with no UV: {missing[:10]}"
    assert conflicts == 0, f"{conflicts} vertices carry more than one UV -- mesh would need splitting"

    tris = [[c[0] for c in t] for t in raw_tris]

    # Every loop edge must be a real mesh edge, or the skin mask will leak.
    edges = set()
    for a, b, c in tris:
        for x, y in ((a, b), (b, c), (c, a)):
            edges.add((min(x, y), max(x, y)))
    for name, loop in LOOPS.items():
        for i in range(len(loop)):
            x, y = loop[i], loop[(i + 1) % len(loop)]
            assert (min(x, y), max(x, y)) in edges, f"{name}: {x}-{y} is not a mesh edge"

    for name, idx in NAMED.items():
        assert 0 <= idx < MESH_VERTEX_COUNT, f"{name} index {idx} out of mesh range"

    xs = [v[0] for v in verts]
    interocular = abs(verts[33][0] - verts[263][0])

    out = {
        "units": "centimeters",
        "source": "mediapipe canonical_face_model.obj",
        "meshVertexCount": MESH_VERTEX_COUNT,
        "landmarkCount": LANDMARK_COUNT,
        "irisLandmarks": IRIS,
        "referenceInterocularCm": round(interocular, 6),
        "bounds": {
            "min": [round(min(v[i] for v in verts), 6) for i in range(3)],
            "max": [round(max(v[i] for v in verts), 6) for i in range(3)],
        },
        "vertices": verts,
        "uvs": uv_by_vertex,
        "triangles": tris,
        "loops": LOOPS,
        "named": NAMED,
    }

    dst = pathlib.Path(__file__).resolve().parents[1] / "canonical" / "face_model.json"
    dst.write_text(json.dumps(out, separators=(",", ":")))
    print(f"ok  {dst.relative_to(pathlib.Path.cwd())}")
    print(f"    {MESH_VERTEX_COUNT} verts  {len(tris)} tris  {len(LOOPS)} loops  {len(NAMED)} named")
    print(f"    reference interocular {interocular:.3f} cm")
    print(f"    {dst.stat().st_size / 1024:.1f} KB")


if __name__ == "__main__":
    main()

//
//  Snake.metal
//  Voiid
//
//  GPU shaders for the Snake arena (docs/GAMES.md §70).
//
//  TWO PIPELINES, deliberately, because the arena is only ever two kinds of thing:
//
//    circles  — food, heads, the arena floor, joystick art. Drawn INSTANCED: one quad, one
//               draw call, N instances. A 300-pellet field is one call, not 300.
//    ribbons  — snake bodies, triangulated on the CPU from the trail polyline and uploaded
//               as a vertex buffer. Bodies change shape every frame, so there is nothing to
//               cache; the win is that all bodies go in a single call.
//
//  Circles are drawn as quads with a distance-field cutoff in the fragment shader rather
//  than as triangle fans. A fan needs ~24 vertices per circle to look round; this needs 4,
//  and the edge is analytically smooth at any zoom instead of faceting when a snake grows.
//

#include <metal_stdlib>
using namespace metal;

/// World -> clip transform, shared by every draw in a frame.
struct Uniforms {
    float2 cameraCentre;   // world point under the middle of the screen
    float2 viewportSize;   // points
    float  scale;          // world units -> points
    float  _pad;
};

// MARK: - Instanced circles

struct CircleInstance {
    float2 centre;         // world
    float  radius;         // world
    float  softness;       // 0 = hard edge, 1 = fully faded (used for glows)
    float4 colour;         // premultiplied-friendly RGBA
};

struct CircleOut {
    float4 position [[position]];
    float2 local;          // -1..1 across the quad, for the distance test
    float4 colour;
    float  softness;
};

/// Convert a world point to Metal clip space.
///
/// Y is negated because the game's world is y-down (it mirrors the server's coordinates and
/// the Canvas renderer it replaces) while clip space is y-up. Doing it here means no other
/// code has to remember the flip.
static float4 worldToClip(float2 world, constant Uniforms &u) {
    float2 view = (world - u.cameraCentre) * u.scale;
    float2 ndc = float2(view.x / (u.viewportSize.x * 0.5),
                        -view.y / (u.viewportSize.y * 0.5));
    return float4(ndc, 0.0, 1.0);
}

vertex CircleOut circleVertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              constant Uniforms &u [[buffer(0)]],
                              constant CircleInstance *instances [[buffer(1)]]) {
    // Unit quad, expanded around the instance centre.
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 corner = corners[vid];

    CircleInstance inst = instances[iid];
    float2 world = inst.centre + corner * inst.radius;

    CircleOut out;
    out.position = worldToClip(world, u);
    out.local = corner;
    out.colour = inst.colour;
    out.softness = inst.softness;
    return out;
}

fragment float4 circleFragment(CircleOut in [[stage_in]]) {
    float d = length(in.local);

    // Analytic antialiasing: fwidth gives the distance change per pixel, so the edge is
    // exactly one pixel wide at ANY zoom. A fixed epsilon would either alias when zoomed in
    // or blur when zoomed out, and the camera here zooms constantly as the snake grows.
    float edge = fwidth(d);
    float alpha = 1.0 - smoothstep(1.0 - max(edge, 0.001) - in.softness, 1.0, d);
    if (alpha <= 0.001) discard_fragment();

    return float4(in.colour.rgb, in.colour.a * alpha);
}

// MARK: - Body ribbons

struct RibbonVertex {
    float2 world;
    float4 colour;
};

struct RibbonOut {
    float4 position [[position]];
    float4 colour;
};

vertex RibbonOut ribbonVertex(uint vid [[vertex_id]],
                              constant Uniforms &u [[buffer(0)]],
                              constant RibbonVertex *verts [[buffer(1)]]) {
    RibbonOut out;
    out.position = worldToClip(verts[vid].world, u);
    out.colour = verts[vid].colour;
    return out;
}

fragment float4 ribbonFragment(RibbonOut in [[stage_in]]) {
    return in.colour;
}

// MARK: - Textured quads (name plates)

struct SpriteInstance {
    float2 centre;         // world
    float2 size;           // world
    float2 uvOrigin;
    float2 uvSize;
    float4 tint;
};

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
    float4 tint;
    /// -1..1 across the quad, so a fragment can tell where it sits within the sprite.
    float2 local;
};

vertex SpriteOut spriteVertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              constant Uniforms &u [[buffer(0)]],
                              constant SpriteInstance *instances [[buffer(1)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 corner = corners[vid];

    SpriteInstance inst = instances[iid];
    float2 world = inst.centre + corner * inst.size * 0.5;

    SpriteOut out;
    out.position = worldToClip(world, u);
    // Quad corners run -1..1; texture coordinates run 0..1 with v flipped, since texture
    // space is top-down and the quad is built bottom-up.
    float2 unit = float2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5);
    out.uv = inst.uvOrigin + unit * inst.uvSize;
    out.tint = inst.tint;
    out.local = corner;
    return out;
}

// This fragment function assumes the SOURCE is a single-channel-meaningful glyph atlas: the
// text is always solid white in the atlas, so only its ALPHA carries shape, and `tint.rgb` is
// what actually colours the label on screen. That is correct for name plates and WRONG for
// anything where the source texture's own colour matters.
/// The arena floor: a tiled lattice, clipped to the arena disc.
///
/// The floor quad is a SQUARE covering the arena's bounding box, so without this clip it
/// spills past the circular boundary — which drew as a huge tinted rectangle swamping the
/// screen and left the lattice visibly ending in mid-air. `local` is the -1..1 quad
/// coordinate, so a length test against it is exactly the inscribed circle.
fragment float4 floorFragment(SpriteOut in [[stage_in]],
                              texture2d<float> tile [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    float d = length(in.local);
    if (d > 1.0) discard_fragment();

    float4 texel = tile.sample(s, in.uv);
    // Fade the last sliver so the lattice meets the boundary softly instead of with a hard
    // cut, which reads as a rendering seam rather than as the edge of a floor.
    float edge = 1.0 - smoothstep(0.97, 1.0, d);
    return float4(texel.rgb, texel.a * in.tint.a * edge);
}

fragment float4 spriteFragment(SpriteOut in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]],
                               sampler s [[sampler(0)]]) {
    float4 texel = atlas.sample(s, in.uv);
    return float4(in.tint.rgb, texel.a * in.tint.a);
}

// Bloom composite (SnakeMetalView.compositeBloom) reuses spriteVertex for the geometry — a
// textured quad is a textured quad — but MUST NOT reuse spriteFragment above: that function
// hardcodes RGB to `tint.rgb`, so compositing the blurred bloom texture through it discarded
// every bit of the bloom's actual colour and painted flat white (only alpha-shaped by
// `texel.a`) additively over the whole frame — which is what made the ENTIRE arena wash out
// to white the instant bloom had any coverage at all, rather than the bloom being invisible.
// This is the actual fix: sample the real texel colour and only use `tint.a` (bloomIntensity)
// to scale it, exactly like a normal additive light composite is supposed to work.
fragment float4 bloomCompositeFragment(SpriteOut in [[stage_in]],
                                       texture2d<float> bloom [[texture(0)]],
                                       sampler s [[sampler(0)]]) {
    float4 texel = bloom.sample(s, in.uv);
    return float4(texel.rgb * in.tint.a, texel.a * in.tint.a);
}

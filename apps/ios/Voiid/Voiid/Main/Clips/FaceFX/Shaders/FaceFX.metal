//
//  FaceFX.metal
//  Voiid
//
//  Every face-FX render pass. Kept line-for-line parallel with the GLSL ES 3.0
//  sources in apps/android/app/src/main/assets/facefx/shaders/ — if you change
//  the maths here, change it there in the same commit or the platforms drift.
//
//  Pass order is fixed (FXPass.allCases):
//    beauty -> colour -> warp -> faceTexture -> occluder -> props -> ambient
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared types

struct FXUniforms {
    float4x4 viewProjection;   // camera projection * view, from ARCamera
    float4x4 headMatrix;       // face-local -> camera space
    float2   resolution;       // render target size, px
    float2   invResolution;
    float    cmToUnits;        // manifest centimetres -> mesh units
    float    time;             // seconds, for animated effects
    float    mirrored;         // 1 when front camera
    float    _pad;
};

struct BeautyParams {
    float smoothStrength;
    float brighten;
    float detailThreshold;
    float blurRadiusPx;
};

struct ColourParams {
    float saturation;
    float contrast;
    float hasLUT;
    float _pad;
};

// A warp control, projected to screen space on the CPU each frame.
struct WarpControl {
    float2 centerPx;
    float  radiusPx;
    float  strength;
    int    mode;        // 0 magnify, 1 pinch, 2 translate
    float2 direction;
    float  _pad;
};

struct PropInstance {
    float4x4 model;     // face-local placement, pre-headMatrix
    float4   uvRect;    // x, y, w, h — normalised atlas coords
    float    opacity;
    float    _pad0, _pad1, _pad2;
};

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

// MARK: - Fullscreen triangle
//
// One oversized triangle rather than two triangles: no diagonal seam, one less
// vertex, and the GPU clips the overhang for free.

vertex FullscreenOut fxFullscreenVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    FullscreenOut out;
    out.uv = uv;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return out;
}

// MARK: - P0  Camera: YCbCr -> RGB
//
// ARKit hands us 420YpCbCr8BiPlanarFullRange. Converting on the GPU keeps the
// CPU out of the pixel path entirely -- the old pipeline's per-frame
// CIContext.render into a fresh BGRA buffer was the main source of its lag.

constant float4x4 kYCbCrToRGB = float4x4(
    float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
    float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
    float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
    float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f));

fragment float4 fxCameraFragment(FullscreenOut in [[stage_in]],
                                 texture2d<float> yPlane  [[texture(0)]],
                                 texture2d<float> cbcrPlane [[texture(1)]],
                                 constant FXUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    if (u.mirrored > 0.5) { uv.x = 1.0 - uv.x; }
    float  y  = yPlane.sample(s, uv).r;
    float2 cc = cbcrPlane.sample(s, uv).rg;
    return kYCbCrToRGB * float4(y, cc.x, cc.y, 1.0);
}

// MARK: - P1  Beauty
//
// Edge-preserving skin smoothing: blur, subtract to get detail, suppress SMALL
// detail (pores, blemishes) while keeping large detail (edges, features), then
// blend back by strength and a face mask. Suppressing everything is what makes
// a cheap beauty filter look like a smear.

fragment float4 fxBlurFragment(FullscreenOut in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               constant float2 &direction [[buffer(0)]],
                               constant FXUniforms &u [[buffer(1)]],
                               constant BeautyParams &p [[buffer(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // 9-tap Gaussian collapsed to 5 linear-interpolated fetches.
    const float offs[3] = {0.0, 1.3846153846, 3.2307692308};
    const float wts[3]  = {0.2270270270, 0.3162162162, 0.0702702703};
    float2 step = direction * u.invResolution * p.blurRadiusPx;
    float3 acc = src.sample(s, in.uv).rgb * wts[0];
    for (int i = 1; i < 3; ++i) {
        acc += src.sample(s, in.uv + step * offs[i]).rgb * wts[i];
        acc += src.sample(s, in.uv - step * offs[i]).rgb * wts[i];
    }
    return float4(acc, 1.0);
}

fragment float4 fxBeautyCombineFragment(FullscreenOut in [[stage_in]],
                                        texture2d<float> original [[texture(0)]],
                                        texture2d<float> blurred  [[texture(1)]],
                                        texture2d<float> skinMask [[texture(2)]],
                                        constant BeautyParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 o = original.sample(s, in.uv).rgb;
    float3 b = blurred.sample(s, in.uv).rgb;
    float  m = skinMask.sample(s, in.uv).r;

    float3 detail = o - b;
    float  mag = max(max(abs(detail.r), abs(detail.g)), abs(detail.b));
    float  keep = smoothstep(p.detailThreshold, p.detailThreshold * 2.5, mag);
    float3 smoothed = b + detail * keep;

    float3 outc = mix(o, smoothed, p.smoothStrength * m);
    outc += p.brighten * m;
    return float4(clamp(outc, 0.0, 1.0), 1.0);
}

// MARK: - P2  Colour
//
// 64^3 LUT as a 512x512 strip (8x8 tiles). One PNG, byte-identical on both
// platforms, so a grade cannot drift between iOS and Android.

static float3 sampleLUT(texture2d<float> strip, sampler s, float3 c) {
    c = clamp(c, 0.0, 1.0);
    float b  = c.b * 63.0;
    float b0 = floor(b);
    float b1 = min(b0 + 1.0, 63.0);
    // +0.5 centres the fetch in its texel; without it, linear sampling bleeds
    // across tile boundaries and the result bands in the blues.
    float2 uv0 = float2(fmod(b0, 8.0) * 64.0 + c.r * 63.0 + 0.5,
                        floor(b0 / 8.0) * 64.0 + c.g * 63.0 + 0.5) / 512.0;
    float2 uv1 = float2(fmod(b1, 8.0) * 64.0 + c.r * 63.0 + 0.5,
                        floor(b1 / 8.0) * 64.0 + c.g * 63.0 + 0.5) / 512.0;
    return mix(strip.sample(s, uv0).rgb, strip.sample(s, uv1).rgb, b - b0);
}

fragment float4 fxColourFragment(FullscreenOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 texture2d<float> lut [[texture(1)]],
                                 constant ColourParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = src.sample(s, in.uv).rgb;
    if (p.hasLUT > 0.5) { c = sampleLUT(lut, s, c); }
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = mix(float3(luma), c, p.saturation);
    c = (c - 0.5) * p.contrast + 0.5;
    return float4(clamp(c, 0.0, 1.0), 1.0);
}

// MARK: - P3  Warp

constant int kMaxWarps = 8;

// Forward warp: where this pixel should SAMPLE from.
static float2 fxWarp(float2 p, constant WarpControl *w, int count) {
    for (int i = 0; i < count && i < kMaxWarps; ++i) {
        float2 v = p - w[i].centerPx;
        float  d = length(v) / max(w[i].radiusPx, 1e-3);
        if (d >= 1.0) { continue; }
        float f = 1.0 - d;
        f = f * f * (3.0 - 2.0 * f);           // smoothstep falloff
        if (w[i].mode == 0) {                  // magnify: sample nearer centre
            p = w[i].centerPx + v * (1.0 - w[i].strength * f);
        } else if (w[i].mode == 1) {           // pinch
            p = w[i].centerPx + v * (1.0 + w[i].strength * f);
        } else {                               // translate
            p += w[i].direction * w[i].strength * w[i].radiusPx * f;
        }
    }
    return p;
}

fragment float4 fxWarpFragment(FullscreenOut in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               constant WarpControl *warps [[buffer(0)]],
                               constant int &count [[buffer(1)]],
                               constant FXUniforms &u [[buffer(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 p = fxWarp(in.uv * u.resolution, warps, count);
    return src.sample(s, p * u.invResolution);
}

// MARK: - P4  Face texture (makeup, stripes, blush)

struct FaceTexOut {
    float4 position [[position]];
    float2 uv;
    float  fade;
};

vertex FaceTexOut fxFaceTexVertex(uint vid [[vertex_id]],
                                  const device float3 *verts [[buffer(0)]],
                                  const device float2 *uvs   [[buffer(1)]],
                                  constant FXUniforms &u     [[buffer(2)]],
                                  constant float4 &uvRect    [[buffer(3)]],
                                  constant float &yawFade    [[buffer(4)]]) {
    FaceTexOut out;
    float4 world = u.headMatrix * float4(verts[vid], 1.0);
    out.position = u.viewProjection * world;
    out.uv = uvRect.xy + uvs[vid] * uvRect.zw;
    out.fade = yawFade;
    return out;
}

fragment float4 fxFaceTexFragment(FaceTexOut in [[stage_in]],
                                  texture2d<float> atlas [[texture(0)]],
                                  constant float &opacity [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = atlas.sample(s, in.uv);
    c *= opacity * in.fade;          // premultiplied alpha
    return c;
}

// MARK: - P5  Occluder depth prepass
//
// Writes depth only. Props then depth-test against the real head, which is what
// lets a glasses arm pass behind a cheek instead of floating over it. Costs
// almost nothing because there is no fragment work at all.

vertex float4 fxOccluderVertex(uint vid [[vertex_id]],
                               const device float3 *verts [[buffer(0)]],
                               constant FXUniforms &u [[buffer(1)]]) {
    return u.viewProjection * (u.headMatrix * float4(verts[vid], 1.0));
}

fragment void fxOccluderFragment() { }

// MARK: - P6  Props
//
// One instanced draw for every layer in a filter. The quad is built in
// FACE-LOCAL space and only then multiplied by headMatrix and the projection,
// so perspective, foreshortening and parallax fall out of the transform chain
// instead of being approximated with a shear.

struct PropOut {
    float4 position [[position]];
    float2 uv;
    float  opacity;
};

vertex PropOut fxPropVertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            const device PropInstance *props [[buffer(0)]],
                            constant FXUniforms &u [[buffer(1)]]) {
    // Unit quad, centred on the origin.
    const float2 corners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5),
                                float2(-0.5,  0.5), float2(0.5,  0.5) };
    const float2 uvs[4]     = { float2(0.0, 1.0), float2(1.0, 1.0),
                                float2(0.0, 0.0), float2(1.0, 0.0) };

    PropInstance p = props[iid];
    float4 local = float4(corners[vid], 0.0, 1.0);
    float4 faceLocal = p.model * local;
    float4 world = u.headMatrix * faceLocal;

    PropOut out;
    out.position = u.viewProjection * world;
    out.uv = p.uvRect.xy + uvs[vid] * p.uvRect.zw;
    out.opacity = p.opacity;
    return out;
}

fragment float4 fxPropFragment(PropOut in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = atlas.sample(s, in.uv);
    return c * in.opacity;          // premultiplied
}

// MARK: - Composite
//
// Final blit. Mirroring happens here, once, at the very end: every coordinate
// upstream stays in unmirrored image space so anchors and manifests never have
// to reason about which camera is active.

fragment float4 fxCompositeFragment(FullscreenOut in [[stage_in]],
                                    texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return src.sample(s, in.uv);
}

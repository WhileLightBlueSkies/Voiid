// The manifest contract. Both platforms parse manifests that satisfy this and
// nothing else; a filter that needs a capability not expressible here needs a
// schema bump, not a special case in platform code.

export const SCHEMA_VERSION = 1;

// Fixed order, matching MediaPipe's output. Manifests reference these by NAME;
// the loader resolves to an index once at load. A MediaPipe version that
// reorders or renames these will fail validation loudly here rather than
// silently mis-drive an effect at runtime.
export const BLENDSHAPES = [
  '_neutral', 'browDownLeft', 'browDownRight', 'browInnerUp', 'browOuterUpLeft',
  'browOuterUpRight', 'cheekPuff', 'cheekSquintLeft', 'cheekSquintRight',
  'eyeBlinkLeft', 'eyeBlinkRight', 'eyeLookDownLeft', 'eyeLookDownRight',
  'eyeLookInLeft', 'eyeLookInRight', 'eyeLookOutLeft', 'eyeLookOutRight',
  'eyeLookUpLeft', 'eyeLookUpRight', 'eyeSquintLeft', 'eyeSquintRight',
  'eyeWideLeft', 'eyeWideRight', 'jawForward', 'jawLeft', 'jawOpen', 'jawRight',
  'mouthClose', 'mouthDimpleLeft', 'mouthDimpleRight', 'mouthFrownLeft',
  'mouthFrownRight', 'mouthFunnel', 'mouthLeft', 'mouthLowerDownLeft',
  'mouthLowerDownRight', 'mouthPressLeft', 'mouthPressRight', 'mouthPucker',
  'mouthRight', 'mouthRollLower', 'mouthRollUpper', 'mouthShrugLower',
  'mouthShrugUpper', 'mouthSmileLeft', 'mouthSmileRight', 'mouthStretchLeft',
  'mouthStretchRight', 'mouthUpperUpLeft', 'mouthUpperUpRight', 'noseSneerLeft',
  'noseSneerRight',
];

// Render passes, in the ONLY order they may run. A manifest lists a subset.
export const PASSES = [
  'beauty', 'colour', 'warp', 'faceTexture', 'occluder', 'props', 'ambient',
];

export const BINDING_TARGETS = [
  'scale.x', 'scale.y', 'scale.uniform', 'opacity',
  'offset.x', 'offset.y', 'offset.z', 'rotation.z', 'atlasFrame',
];

// Targets that COMBINE multiplicatively when several bindings drive them;
// everything else sums. Documented here so both platforms agree.
export const MULTIPLICATIVE_TARGETS = new Set([
  'scale.x', 'scale.y', 'scale.uniform', 'opacity',
]);

export const WARP_MODES = ['magnify', 'pinch', 'translate'];
export const BLEND_MODES = ['normal', 'multiply', 'screen', 'overlay'];
export const BILLBOARD_MODES = ['none', 'y', 'full'];
export const PHYSICS_DRIVERS = ['headRollVelocity', 'headYawVelocity', 'headPitchVelocity'];

export const MAX_TIER = 3;         // 1 = flagship only ... 3 = runs anywhere
export const MAX_PARTICLES = 200;
export const PACK_WARN_BYTES = 400 * 1024;
export const PACK_FAIL_BYTES = 600 * 1024;

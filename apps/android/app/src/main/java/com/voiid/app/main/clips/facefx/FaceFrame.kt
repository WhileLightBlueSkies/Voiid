package com.voiid.app.main.clips.facefx

/**
 * One tracked face at one instant. Mirrors FaceFrame.swift field for field --
 * if you change one, change both, or the shared manifests stop meaning the
 * same thing on the two platforms.
 *
 * Units are load-bearing. [vertices] are **centimetres in canonical-model
 * space** (origin near the nose bridge, face about 15.3 cm wide) and
 * [headMatrix] maps that into metric camera space. Manifest offsets are in the
 * same centimetres and are applied *before* [headMatrix], which is what makes a
 * prop inherit head rotation without any per-prop maths.
 *
 * Unlike iOS, Android's tracker runs asynchronously on its own thread, so the
 * pose here may have been EXTRAPOLATED forward to the current display time --
 * see [PoseStabilizer].
 */
class FaceFrame {
    /** Capture time, not receipt time: extrapolation is only correct against
     *  the instant the photons arrived. */
    var timestampNanos: Long = 0L

    /** False when no face is present. The renderer must show a clean camera,
     *  not the last known pose. */
    var valid: Boolean = false

    /** 478 landmarks as flat xyz. 0..467 are canonical mesh vertices;
     *  468..477 are iris points with no mesh position, never rendered. */
    var vertices: FloatArray = FloatArray(LANDMARK_COUNT * 3)

    /** 52 coefficients, 0..1, in Blendshape order. */
    var blendshapes: FloatArray = FloatArray(BLENDSHAPE_COUNT)

    /** Canonical space -> metric camera space, column-major (OpenGL order). */
    var headMatrix: FloatArray = floatArrayOf(
        1f, 0f, 0f, 0f,
        0f, 1f, 0f, 0f,
        0f, 0f, 1f, 0f,
        0f, 0f, 0f, 1f,
    )

    /**
     * Multiply a manifest's centimetre value by this to get mesh units.
     * Android's mesh IS the canonical model, so this is 1. It exists so the
     * renderer maths is identical to iOS, where ARKit's mesh is in metres.
     */
    var cmToUnits: Float = 1f

    var imageWidth: Int = 0
    var imageHeight: Int = 0

    /** True for the front camera. Mirroring happens once, at the very end of
     *  the pass chain, so everything here is unmirrored image space. */
    var mirrored: Boolean = false

    var interocularCm: Float = 8.892f

    /** Head angular velocity in rad/s, for spring-driven layers. */
    var angularVelocity: FloatArray = FloatArray(3)

    fun vertex(index: Int, out: FloatArray) {
        val i = index * 3
        out[0] = vertices[i]; out[1] = vertices[i + 1]; out[2] = vertices[i + 2]
    }

    fun copyFrom(other: FaceFrame) {
        timestampNanos = other.timestampNanos
        valid = other.valid
        other.vertices.copyInto(vertices)
        other.blendshapes.copyInto(blendshapes)
        other.headMatrix.copyInto(headMatrix)
        cmToUnits = other.cmToUnits
        imageWidth = other.imageWidth
        imageHeight = other.imageHeight
        mirrored = other.mirrored
        interocularCm = other.interocularCm
        other.angularVelocity.copyInto(angularVelocity)
    }

    companion object {
        const val LANDMARK_COUNT = 478
        const val MESH_VERTEX_COUNT = 468
        const val BLENDSHAPE_COUNT = 52
    }
}

/**
 * MediaPipe's 52 blendshapes in its fixed output order.
 *
 * Manifests reference these by NAME and the loader resolves to an index once,
 * so a MediaPipe release that reorders them fails loudly at load rather than
 * silently driving the wrong effect.
 *
 * iOS reaches the same 52 slots through ARKit, whose taxonomy MediaPipe copied.
 * The sets overlap in 51 of 52: MediaPipe has `_neutral` where ARKit has
 * `tongueOut`. Every name a manifest may reference is in the shared 51.
 */
object Blendshape {
    val NAMES = arrayOf(
        "_neutral", "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft",
        "browOuterUpRight", "cheekPuff", "cheekSquintLeft", "cheekSquintRight",
        "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft", "eyeLookDownRight",
        "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight",
        "eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight",
        "eyeWideLeft", "eyeWideRight", "jawForward", "jawLeft", "jawOpen", "jawRight",
        "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft",
        "mouthFrownRight", "mouthFunnel", "mouthLeft", "mouthLowerDownLeft",
        "mouthLowerDownRight", "mouthPressLeft", "mouthPressRight", "mouthPucker",
        "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower",
        "mouthShrugUpper", "mouthSmileLeft", "mouthSmileRight", "mouthStretchLeft",
        "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight", "noseSneerLeft",
        "noseSneerRight",
    )

    private val byName: Map<String, Int> =
        NAMES.withIndex().associate { (i, n) -> n to i }

    fun index(name: String): Int? = byName[name]

    const val JAW_OPEN = 25
}

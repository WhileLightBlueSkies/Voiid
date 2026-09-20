package com.voiid.app.main.clips

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap

/**
 * Photoreal filter art, and where each piece sits on a face.
 *
 * Replaces the hand-drawn vector paths. Those could describe a shape but never a
 * material - flat fills have no way to say "fur" or "gold" - so every filter read as a
 * cartoon no matter how the placement was tuned.
 *
 * ## The placement model
 *
 * Everything is expressed in units of **D**, the interocular distance, because D is the
 * one measurement that scales with the face and is independent of camera resolution,
 * distance and lens. A layer says how wide it is, how far up the face's own axis it sits,
 * and how far out to the side - never anything in pixels.
 *
 * Height is NOT specified: it comes from the bitmap's aspect ratio. The old 512x512
 * sprite-box convention is gone with the vector art, and with it the need to keep art and
 * placement constants agreeing about where the edges of an invisible box were.
 *
 * Reference proportions, measured from the device:
 *   top of head  ~1.9 D above the eye line   (NOT the ML Kit box, which stops at the brow)
 *   head width   ~2.6 D
 *   nose base    ~0.55 D below the eye line
 *   mouth        ~1.0 D below the eye line
 */

enum class FxAnchor { EYES, NOSE, MOUTH }

/**
 * One drawn piece.
 *
 * @param widthD    width in units of D; height follows the bitmap's aspect
 * @param riseD     distance along the face's UP axis from the anchor (negative = down)
 * @param outD      distance along the face's RIGHT axis; a [mirrored] layer draws at both
 *                  -outD and +outD
 * @param mirrored  true for pairs: one bitmap, drawn twice, flipped on the second copy, so
 *                  the two sides can never drift apart the way two AI-generated ears would
 * @param flipBase  flips the un-mirrored copy, for source art that faces the wrong way
 * @param wobble    carries the ear spring, so only soft things bounce
 * @param openMouth if set, the layer only draws once mouthOpenness passes this
 * @param pivotX    where the anchor sits INSIDE the bitmap, as a fraction of its size
 * @param pivotY    likewise vertically. Measured, not guessed: a tiger mask's eye holes
 *                  are at 0.42 of its height and a tiger muzzle's nose pad at 0.22, so
 *                  pinning either bitmap by its centre hangs the feature off the face.
 */
data class FxLayer(
    val asset: String,
    val anchor: FxAnchor,
    val widthD: Float,
    val riseD: Float = 0f,
    val outD: Float = 0f,
    val mirrored: Boolean = false,
    val flipBase: Boolean = false,
    val wobble: Boolean = false,
    val openMouth: Float? = null,
    val pivotX: Float = 0.5f,
    val pivotY: Float = 0.5f,
)

object ClipFaceArt {

    /**
     * Layers are drawn in list order, so things meant to sit behind the face - ears,
     * horns, a hat - come before anything that sits on it.
     */
    val layers: Map<ClipFaceEffect, List<FxLayer>> = mapOf(
        ClipFaceEffect.NONE to emptyList(),

        ClipFaceEffect.DOG to listOf(
            FxLayer("dog_ear_left", FxAnchor.EYES, widthD = 0.95f, riseD = 1.35f,
                    outD = 0.95f, mirrored = true, wobble = true),
            FxLayer("dog_nose", FxAnchor.NOSE, widthD = 0.82f, riseD = -0.04f,
                    pivotY = 0.47f),
            // Only when the mouth actually opens, which is the whole joke.
            FxLayer("dog_tongue", FxAnchor.MOUTH, widthD = 0.50f, riseD = -0.42f,
                    openMouth = 0.15f, pivotY = 0.10f),
        ),

        ClipFaceEffect.TIGER to listOf(
            FxLayer("tiger_ear_left", FxAnchor.EYES, widthD = 0.85f, riseD = 1.28f,
                    outD = 0.86f, mirrored = true, wobble = true),
            // The mask and the muzzle together make the face, so both are pinned by their
            // own features - eye holes at 0.42, nose pad at 0.22 - not by their centres.
            FxLayer("tiger_stripes", FxAnchor.EYES, widthD = 2.50f, riseD = 0.0f,
                    pivotY = 0.42f),
            FxLayer("tiger_nose", FxAnchor.NOSE, widthD = 1.60f, riseD = -0.02f,
                    pivotY = 0.22f),
        ),

        ClipFaceEffect.PARTY to listOf(
            FxLayer("party_hat", FxAnchor.EYES, widthD = 1.15f, riseD = 2.55f),
        ),

        ClipFaceEffect.CYBER to listOf(
            FxLayer("cyber_visor", FxAnchor.EYES, widthD = 2.35f, riseD = 0.06f),
        ),

        ClipFaceEffect.BUNNY to listOf(
            FxLayer("bunny_ear_left", FxAnchor.EYES, widthD = 0.46f, riseD = 2.10f,
                    outD = 0.48f, mirrored = true, wobble = true),
            FxLayer("bunny_nose", FxAnchor.NOSE, widthD = 1.10f, riseD = -0.02f,
                    pivotY = 0.29f),
        ),

        ClipFaceEffect.KOALA to listOf(
            FxLayer("koala_ear_left", FxAnchor.EYES, widthD = 1.15f, riseD = 1.45f,
                    outD = 1.20f, mirrored = true, wobble = true),
            FxLayer("koala_nose", FxAnchor.NOSE, widthD = 0.86f, riseD = -0.02f,
                    pivotY = 0.58f),
        ),

        ClipFaceEffect.CAT to listOf(
            FxLayer("cat_ear_left", FxAnchor.EYES, widthD = 0.88f, riseD = 1.50f,
                    outD = 0.88f, mirrored = true, flipBase = true, wobble = true),
            // A muzzle, not a nose: it has to reach the mouth, so it is wider than the
            // nose pad it is pinned by.
            FxLayer("cat_nose", FxAnchor.NOSE, widthD = 1.50f, riseD = -0.02f,
                    pivotY = 0.44f),
            FxLayer("cat_whiskers", FxAnchor.NOSE, widthD = 2.45f, riseD = -0.02f),
        ),

        ClipFaceEffect.SUNGLASSES to listOf(
            FxLayer("sunglasses", FxAnchor.EYES, widthD = 2.35f, riseD = 0.06f),
        ),

        // Sized to the head (~2.6 D wide) rather than to the face box, and dropped so the
        // band beds into the hair instead of hovering above it.
        ClipFaceEffect.CROWN to listOf(
            FxLayer("crown", FxAnchor.EYES, widthD = 2.85f, riseD = 1.95f),
        ),

        // The source ring is 347x116 (aspect 2.99). It was extracted clipped twice - the
        // crop box cut through the right of the ring - which made it look both narrower
        // and taller than it is, so the old width was tuned against a broken sprite.
        ClipFaceEffect.HALO to listOf(
            FxLayer("halo", FxAnchor.EYES, widthD = 2.45f, riseD = 2.50f),
        ),

        // flipBase: the source horn curves one way, and drawn unflipped on the left the
        // pair curled inward at each other like ram's horns.
        ClipFaceEffect.DEVIL to listOf(
            FxLayer("devil_horn_left", FxAnchor.EYES, widthD = 0.60f, riseD = 1.85f,
                    outD = 0.60f, mirrored = true, flipBase = true),
        ),
    )
}

/**
 * Loads and holds the filter bitmaps.
 *
 * Decoding happens once, off the draw path. A miss returns null and the layer is skipped
 * rather than throwing - a filter with one missing piece is still usable, and a camera
 * that crashes is not.
 */
object ClipFaceAssets {

    private val cache = HashMap<String, ImageBitmap?>()
    private val lock = Any()

    @Volatile
    var ready: Boolean = false
        private set

    fun get(name: String): ImageBitmap? = synchronized(lock) { cache[name] }

    /** Call off the main thread. Safe to call more than once. */
    fun preload(context: Context) {
        val names = ClipFaceArt.layers.values.flatten().map { it.asset }.distinct()
        val loaded = HashMap<String, ImageBitmap?>(names.size)
        for (n in names) {
            loaded[n] = runCatching {
                context.assets.open("filters/$n.png").use { s ->
                    BitmapFactory.decodeStream(s)?.asImageBitmap()
                }
            }.getOrNull()
        }
        synchronized(lock) {
            cache.putAll(loaded)
            ready = true
        }
    }
}

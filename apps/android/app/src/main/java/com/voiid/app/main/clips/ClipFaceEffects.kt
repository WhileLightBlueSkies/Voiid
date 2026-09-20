package com.voiid.app.main.clips

import android.graphics.PointF
import android.graphics.RectF
import androidx.annotation.OptIn
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceContour
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

// MARK: - Effect catalogue

enum class ClipFaceEffect(val label: String, val icon: String) {
    NONE("None", "⊘"),
    DOG("Puppy", "🐶"),
    TIGER("Wildcat", "🐯"),
    PARTY("Party", "🎉"),
    CYBER("Cyber", "🕶️"),
    BUNNY("Bunny", "🐰"),
    KOALA("Koala", "🐨"),
    CAT("Cat", "🐱"),
    SUNGLASSES("Shades", "😎"),
    CROWN("Crown", "👑"),
    HALO("Halo", "😇"),
    DEVIL("Devil", "😈");

    val isEyewear: Boolean
        get() = this == SUNGLASSES || this == CYBER

    val hasReactiveMouth: Boolean
        get() = this == DOG || this == TIGER || this == PARTY
}

// MARK: - Tracked face

data class TrackedFace(
    val box: RectF,
    val eyeMid: Offset,
    val eyeDistance: Float,
    val roll: Float,          // radians
    val yaw: Float,           // radians
    val pitch: Float,         // radians
    val nose: Offset,
    val mouthMid: Offset,
    val mouthOpenness: Float, // 0.0 (closed) to 1.0 (wide open)
    val smilingRatio: Float,  // 0.0 to 1.0
    val earWobble: Float,     // radians of spring wobble
    val hasLandmarks: Boolean,
    val isCanvasMapped: Boolean = false
)

// MARK: - Physics & One Euro filter

class SpringState(
    private val stiffness: Float = 160f,
    private val damping: Float = 12f
) {
    private var pos = 0f
    private var vel = 0f

    fun update(target: Float, dt: Float): Float {
        val force = -stiffness * (pos - target) - damping * vel
        vel += force * dt
        pos += vel * dt
        return pos
    }

    fun reset() {
        pos = 0f
        vel = 0f
    }
}

class OneEuroFilter(
    private val minCutoff: Float,
    private val beta: Float,
    private val dCutoff: Float = 1.0f
) {
    private var xPrev = 0f
    private var dxPrev = 0f
    private var hasPrev = false

    private fun alpha(cutoff: Float, dt: Float): Float {
        val tau = 1f / (2f * PI.toFloat() * cutoff)
        return 1f / (1f + tau / dt)
    }

    fun filter(x: Float, dt: Float): Float {
        if (!hasPrev || dt <= 0f) {
            xPrev = x
            dxPrev = 0f
            hasPrev = true
            return x
        }
        val dx = (x - xPrev) / dt
        val aD = alpha(dCutoff, dt)
        val edx = aD * dx + (1f - aD) * dxPrev
        val cutoff = minCutoff + beta * abs(edx)
        val a = alpha(cutoff, dt)
        val xHat = a * x + (1f - a) * xPrev
        xPrev = xHat
        dxPrev = edx
        return xHat
    }

    fun reset() {
        hasPrev = false
    }
}

private class FaceSmoother {
    val eyeMidX   = OneEuroFilter(2.2f, 0.04f)
    val eyeMidY   = OneEuroFilter(2.2f, 0.04f)
    val dist      = OneEuroFilter(1.8f, 0.02f)
    val roll      = OneEuroFilter(2.5f, 0.15f)
    val yaw       = OneEuroFilter(2.0f, 0.12f)
    val pitch     = OneEuroFilter(2.0f, 0.12f)
    val noseX     = OneEuroFilter(2.2f, 0.04f)
    val noseY     = OneEuroFilter(2.2f, 0.04f)
    val mouthMidX = OneEuroFilter(2.2f, 0.04f)
    val mouthMidY = OneEuroFilter(2.2f, 0.04f)
    val mouthOpen = OneEuroFilter(3.2f, 0.22f)
    val smile     = OneEuroFilter(2.0f, 0.10f)
    val earWobble = SpringState()

    fun reset() {
        eyeMidX.reset(); eyeMidY.reset(); dist.reset()
        roll.reset(); yaw.reset(); pitch.reset()
        noseX.reset(); noseY.reset(); mouthMidX.reset(); mouthMidY.reset()
        mouthOpen.reset(); smile.reset()
        earWobble.reset()
    }
}

// MARK: - Detector

class ClipFaceDetector : ImageAnalysis.Analyzer {

    private val detector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL)
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
            .setMinFaceSize(0.12f)
            .build()
    )

    private val lock = Any()
    private var _latest: TrackedFace? = null
    private var smoother = FaceSmoother()
    private var hadFace = false
    private var lastPublishTime = 0L
    private var lastDistance = 0f
    private var lastRoll = 0f
    private var isBusy = false

    var isFrontCamera by mutableStateOf(false)
    var sourceWidth by mutableStateOf(720f)
    var sourceHeight by mutableStateOf(1280f)
    var trackedFace by mutableStateOf<TrackedFace?>(null)
    @Volatile var activeEffect: ClipFaceEffect = ClipFaceEffect.NONE

    /** Size of the on-screen preview, in px. Landmarks are mapped into this space. */
    @Volatile var viewWidth: Float = 0f
    @Volatile var viewHeight: Float = 0f

    val latest: TrackedFace?
        get() = synchronized(lock) { _latest }

    fun reset() {
        synchronized(lock) {
            _latest = null
            smoother.reset()
            hadFace = false
            lastPublishTime = 0L
            lastDistance = 0f
            lastRoll = 0f
        }
        trackedFace = null
    }

    fun close() {
        runCatching { detector.close() }
    }

    @OptIn(ExperimentalGetImage::class)
    override fun analyze(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }

        synchronized(lock) {
            if (isBusy) {
                imageProxy.close()
                return
            }
            isBusy = true
        }

        val rotation = imageProxy.imageInfo.rotationDegrees
        val image = InputImage.fromMediaImage(mediaImage, rotation)

        val imageWidth = if (rotation == 90 || rotation == 270) imageProxy.height else imageProxy.width
        val imageHeight = if (rotation == 90 || rotation == 270) imageProxy.width else imageProxy.height

        detector.process(image)
            .addOnSuccessListener { faces ->
                val primaryFace = faces.maxByOrNull { it.boundingBox.width() }
                if (primaryFace == null) {
                    synchronized(lock) {
                        _latest = null
                        hadFace = false
                    }
                    trackedFace = null
                } else {
                    processFace(primaryFace, imageWidth.toFloat(), imageHeight.toFloat())
                }
            }
            .addOnCompleteListener {
                synchronized(lock) { isBusy = false }
                imageProxy.close()
            }
    }

    /**
     * Maps one detected face from ML Kit's image space into the on-screen canvas.
     *
     * Done explicitly rather than with CameraX's CoordinateTransform. That API is only
     * defined between use cases sharing a ViewPort, and even with one bound it kept
     * transposing the image dimensions: a square 329x329 ML Kit box arrived as 408x1292,
     * x divided by 1280/720 and y multiplied by it. The mapping below is four lines of
     * arithmetic with no hidden contract, and it is exact as long as PreviewView stays on
     * FILL_CENTER and the analysis stream shares the preview's aspect ratio (a shared
     * 9:16 ViewPort guarantees the second part).
     */
    private fun processFace(
        face: Face,
        imgW: Float,
        imgH: Float
    ) {
        val viewW = viewWidth
        val viewH = viewHeight
        if (viewW <= 0f || viewH <= 0f || imgW <= 0f || imgH <= 0f) return

        // PreviewView.ScaleType.FILL_CENTER: scale uniformly until both axes are covered,
        // then centre. Uniform is the whole point - a per-axis scale is what distorted the
        // box before.
        val scale = max(viewW / imgW, viewH / imgH)
        val offX = (viewW - imgW * scale) / 2f
        val offY = (viewH - imgH * scale) / 2f
        val mirror = isFrontCamera

        fun mapX(x: Float): Float {
            val vx = x * scale + offX
            // ImageAnalysis frames are never mirrored; PreviewView mirrors the front lens
            // for display, so the landmarks have to follow it.
            return if (mirror) viewW - vx else vx
        }
        fun mapY(y: Float): Float = y * scale + offY
        fun mapPoint(p: PointF): Offset = Offset(mapX(p.x), mapY(p.y))

        fun contourCentroid(type: Int): PointF? {
            val pts = face.getContour(type)?.points
            if (pts.isNullOrEmpty()) return null
            return PointF(
                pts.map { it.x }.average().toFloat(),
                pts.map { it.y }.average().toFloat(),
            )
        }

        val rawLeftEye = contourCentroid(FaceContour.LEFT_EYE)
            ?: face.getLandmark(FaceLandmark.LEFT_EYE)?.position
        val rawRightEye = contourCentroid(FaceContour.RIGHT_EYE)
            ?: face.getLandmark(FaceLandmark.RIGHT_EYE)?.position
        // NOSE_BASE (the midpoint of the nostrils) rather than the NOSE_BRIDGE contour,
        // whose centroid lands up BETWEEN THE EYES. Snouts, button noses and whiskers all
        // hang off this point, and anchoring them to the bridge put them on the brow.
        val rawNose = face.getLandmark(FaceLandmark.NOSE_BASE)?.position
            ?: contourCentroid(FaceContour.NOSE_BRIDGE)
            ?: PointF(
                face.boundingBox.centerX().toFloat(),
                face.boundingBox.top + face.boundingBox.height() * 0.55f,
            )

        // Box corners map individually, then min/max: mirroring swaps left and right.
        val rawBox = face.boundingBox
        val bx1 = mapX(rawBox.left.toFloat())
        val bx2 = mapX(rawBox.right.toFloat())
        val bounds = RectF(
            min(bx1, bx2), mapY(rawBox.top.toFloat()),
            max(bx1, bx2), mapY(rawBox.bottom.toFloat()),
        )

        val mappedA = rawLeftEye?.let { mapPoint(it) }
        val mappedB = rawRightEye?.let { mapPoint(it) }
        val hasLandmarks = mappedA != null && mappedB != null

        // After mirroring, "left" means smaller x on screen, which is what the roll angle
        // has to be measured from.
        val screenLeft: Offset?
        val screenRight: Offset?
        if (mappedA != null && mappedB != null) {
            if (mappedA.x <= mappedB.x) { screenLeft = mappedA; screenRight = mappedB }
            else { screenLeft = mappedB; screenRight = mappedA }
        } else {
            screenLeft = mappedA ?: mappedB
            screenRight = null
        }

        val eyeDistance = if (screenLeft != null && screenRight != null) {
            hypot(screenRight.x - screenLeft.x, screenRight.y - screenLeft.y).coerceAtLeast(1f)
        } else {
            (bounds.width() * 0.46f).coerceAtLeast(1f)
        }

        val eyeMid = if (screenLeft != null && screenRight != null) {
            Offset((screenLeft.x + screenRight.x) / 2f, (screenLeft.y + screenRight.y) / 2f)
        } else {
            Offset(bounds.centerX(), bounds.top + bounds.height() * 0.38f)
        }

        // Measured between the mapped eyes, so mirroring is already accounted for and no
        // sign flip is needed. Screen space has y down, hence the direct atan2.
        val rollRad = if (screenLeft != null && screenRight != null) {
            atan2(screenRight.y - screenLeft.y, screenRight.x - screenLeft.x)
        } else {
            val z = Math.toRadians(face.headEulerAngleZ.toDouble()).toFloat()
            if (mirror) z else -z
        }

        val yawRad = Math.toRadians(-face.headEulerAngleY.toDouble()).toFloat()
            .let { if (mirror) -it else it }
        val pitchRad = Math.toRadians(face.headEulerAngleX.toDouble()).toFloat()

        val nose = mapPoint(rawNose)

        // Mouth, measured along the face's own up axis rather than the screen's. A rolled
        // head projects some of the mouth's WIDTH onto screen-y, which read as openness.
        val up = Offset(sin(rollRad), -cos(rollRad))
        var mouthMid = Offset(bounds.centerX(), bounds.top + bounds.height() * 0.72f)
        var rawMouthOpen = 0f

        val upperLip = face.getContour(FaceContour.UPPER_LIP_BOTTOM)?.points
        val lowerLip = face.getContour(FaceContour.LOWER_LIP_TOP)?.points
        if (!upperLip.isNullOrEmpty() && !lowerLip.isNullOrEmpty()) {
            val upper = Offset(
                mapX(upperLip.map { it.x }.average().toFloat()),
                mapY(upperLip.map { it.y }.average().toFloat()),
            )
            val lower = Offset(
                mapX(lowerLip.map { it.x }.average().toFloat()),
                mapY(lowerLip.map { it.y }.average().toFloat()),
            )
            val gap = abs((lower.x - upper.x) * up.x + (lower.y - upper.y) * up.y)
            rawMouthOpen = ((gap / (eyeDistance * 0.42f) - 0.08f) / 0.38f).coerceIn(0f, 1f)
            mouthMid = Offset((upper.x + lower.x) / 2f, (upper.y + lower.y) / 2f)
        } else {
            val mouthLeft = face.getLandmark(FaceLandmark.MOUTH_LEFT)?.position
            val mouthRight = face.getLandmark(FaceLandmark.MOUTH_RIGHT)?.position
            val mouthBottom = face.getLandmark(FaceLandmark.MOUTH_BOTTOM)?.position
            if (mouthLeft != null && mouthRight != null) {
                val l = mapPoint(mouthLeft)
                val r = mapPoint(mouthRight)
                mouthMid = Offset((l.x + r.x) / 2f, (l.y + r.y) / 2f)
                if (mouthBottom != null) {
                    val b = mapPoint(mouthBottom)
                    val gap = abs((b.x - mouthMid.x) * up.x + (b.y - mouthMid.y) * up.y)
                    rawMouthOpen = (gap / (eyeDistance * 0.50f) - 0.10f).coerceIn(0f, 1f)
                }
            }
        }

        publish(
            width = imgW,
            height = imgH,
            bounds = bounds,
            eyeMid = eyeMid,
            eyeDistance = eyeDistance,
            roll = rollRad,
            yaw = yawRad,
            pitch = pitchRad,
            nose = nose,
            mouthMid = mouthMid,
            mouthOpen = rawMouthOpen,
            smile = face.smilingProbability ?: 0f,
            hasLandmarks = hasLandmarks,
            isCanvasMapped = true,
        )
    }

    private fun publish(
        width: Float,
        height: Float,
        bounds: RectF,
        eyeMid: Offset,
        eyeDistance: Float,
        roll: Float,
        yaw: Float,
        pitch: Float,
        nose: Offset,
        mouthMid: Offset,
        mouthOpen: Float,
        smile: Float,
        hasLandmarks: Boolean,
        isCanvasMapped: Boolean
    ) {
        val now = System.currentTimeMillis()
        val publishedFace: TrackedFace
        synchronized(lock) {
            val dt = min(0.1f, max(1f / 60f, if (hadFace) (now - lastPublishTime) / 1000f else 1f / 30f))
            lastPublishTime = now

            val scaleJump = lastDistance > 0 && abs(eyeDistance - lastDistance) / lastDistance > 0.40f
            if (!hadFace || scaleJump) {
                smoother.reset()
            }
            hadFace = true
            lastDistance = eyeDistance

            val rollVel = (roll - lastRoll) / dt
            lastRoll = roll
            val wobble = smoother.earWobble.update(-rollVel * 0.08f, dt)

            publishedFace = TrackedFace(
                box = bounds,
                eyeMid = Offset(smoother.eyeMidX.filter(eyeMid.x, dt), smoother.eyeMidY.filter(eyeMid.y, dt)),
                eyeDistance = smoother.dist.filter(eyeDistance, dt),
                roll = smoother.roll.filter(roll, dt),
                yaw = smoother.yaw.filter(yaw, dt),
                pitch = smoother.pitch.filter(pitch, dt),
                nose = Offset(smoother.noseX.filter(nose.x, dt), smoother.noseY.filter(nose.y, dt)),
                mouthMid = Offset(smoother.mouthMidX.filter(mouthMid.x, dt), smoother.mouthMidY.filter(mouthMid.y, dt)),
                mouthOpenness = smoother.mouthOpen.filter(mouthOpen, dt),
                smilingRatio = smoother.smile.filter(smile, dt),
                earWobble = wobble,
                hasLandmarks = hasLandmarks,
                isCanvasMapped = isCanvasMapped
            )
            _latest = publishedFace
        }
        sourceWidth = width
        sourceHeight = height
        trackedFace = publishedFace
    }
}

// MARK: - Renderer

object ClipFaceRenderer {

    /**
     * Draws the filter's layers onto the preview.
     *
     * The face arrives already mapped into canvas space (see ClipFaceDetector), so there is
     * no coordinate work left here - only placing bitmaps along the face's own up/right
     * axes so a tilted head carries its props with it.
     */
    fun DrawScope.drawFaceEffect(
        face: TrackedFace,
        effect: ClipFaceEffect,
        previewWidth: Float,
        previewHeight: Float,
        cameraSourceWidth: Float,
        cameraSourceHeight: Float,
        nowMs: Long = System.currentTimeMillis()
    ) {
        val layers = ClipFaceArt.layers[effect].orEmpty()
        if (layers.isEmpty()) return

        // Landmarks are published in canvas space; the fallback only matters before the
        // view has been measured.
        val scaleFactor = max(previewWidth / cameraSourceWidth, previewHeight / cameraSourceHeight)
        val offsetX = (previewWidth - cameraSourceWidth * scaleFactor) / 2f
        val offsetY = (previewHeight - cameraSourceHeight * scaleFactor) / 2f
        fun mapPoint(p: Offset) = Offset(p.x * scaleFactor + offsetX, p.y * scaleFactor + offsetY)

        val D = if (face.isCanvasMapped) face.eyeDistance else face.eyeDistance * scaleFactor
        val eyeMid = if (face.isCanvasMapped) face.eyeMid else mapPoint(face.eyeMid)
        val nose = if (face.isCanvasMapped) face.nose else mapPoint(face.nose)
        val mouthMid = if (face.isCanvasMapped) face.mouthMid else mapPoint(face.mouthMid)
        if (D <= 1f) return

        val rollDeg = Math.toDegrees(face.roll.toDouble()).toFloat()
        val wobbleDeg = Math.toDegrees(face.earWobble.toDouble()).toFloat()

        // Screen space has y down, so up is (sin roll, -cos roll).
        val up = Offset(sin(face.roll), -cos(face.roll))
        val right = Offset(cos(face.roll), sin(face.roll))

        // Turning the head narrows everything you see of it. Floored so a big yaw cannot
        // squash a prop to nothing.
        val yawSquash = cos(face.yaw).coerceAtLeast(0.55f)

        for (layer in layers) {
            val bmp = ClipFaceAssets.get(layer.asset) ?: continue
            if (layer.openMouth != null && face.mouthOpenness < layer.openMouth) continue

            val anchor = when (layer.anchor) {
                FxAnchor.EYES -> eyeMid
                FxAnchor.NOSE -> nose
                FxAnchor.MOUTH -> mouthMid
            }

            val w = layer.widthD * D * yawSquash
            val h = w / (bmp.width.toFloat() / bmp.height.toFloat()) / yawSquash
            val angle = rollDeg + if (layer.wobble) wobbleDeg else 0f

            val sides = if (layer.mirrored) listOf(-1f, 1f) else listOf(0f)
            for (side in sides) {
                val outward = layer.outD * D * side
                val pos = Offset(
                    anchor.x + up.x * (layer.riseD * D) + right.x * outward,
                    anchor.y + up.y * (layer.riseD * D) + right.y * outward,
                )
                // One bitmap flipped for the far side: two ears cut from one sprite can
                // never disagree with each other.
                val flip = if (side > 0f) !layer.flipBase else layer.flipBase
                drawSprite(bmp, pos, w, h, angle, flip, layer.pivotX, layer.pivotY)
            }
        }
    }

    /**
     * @param at      where the layer's pivot feature must land on the face
     * @param pivotX  the pivot's position inside the bitmap, as a fraction. The image is
     *                offset so this point, not the bitmap's centre, sits on [at] - and
     *                rotation and mirroring happen about [at] too, so a rolled head swings
     *                a prop around its attachment rather than around its middle.
     */
    private fun DrawScope.drawSprite(
        bmp: ImageBitmap,
        at: Offset,
        w: Float,
        h: Float,
        angleDeg: Float,
        flipX: Boolean,
        pivotX: Float,
        pivotY: Float,
    ) {
        rotate(degrees = angleDeg, pivot = at) {
            scale(
                scaleX = if (flipX) -1f else 1f,
                scaleY = 1f,
                pivot = at,
            ) {
                drawImage(
                    image = bmp,
                    srcOffset = IntOffset.Zero,
                    srcSize = IntSize(bmp.width, bmp.height),
                    dstOffset = IntOffset(
                        (at.x - w * pivotX).roundToInt(),
                        (at.y - h * pivotY).roundToInt(),
                    ),
                    dstSize = IntSize(w.roundToInt(), h.roundToInt()),
                    filterQuality = FilterQuality.High,
                )
            }
        }
    }
}

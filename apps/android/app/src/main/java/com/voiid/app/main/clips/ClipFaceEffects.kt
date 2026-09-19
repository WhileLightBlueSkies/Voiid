package com.voiid.app.main.clips

import android.graphics.PointF
import android.graphics.RectF
import androidx.annotation.OptIn
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.view.transform.CoordinateTransform
import androidx.camera.view.transform.ImageProxyTransformFactory
import androidx.camera.view.transform.OutputTransform
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
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
import kotlin.math.sin
import kotlin.math.tan

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
    @Volatile var previewTransform: OutputTransform? = null

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

        val target = previewTransform
        val imageTransform = runCatching {
            ImageProxyTransformFactory().apply {
                isUsingRotationDegrees = true
                isUsingCropRect = false
            }.getOutputTransform(imageProxy)
        }.getOrNull()

        val mappingMatrix = if (target != null && imageTransform != null) {
            runCatching {
                val coordTransform = CoordinateTransform(imageTransform, target)
                android.graphics.Matrix().also { coordTransform.transform(it) }
            }.getOrNull()
        } else null

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
                    processFace(primaryFace, mappingMatrix, imageWidth.toFloat(), imageHeight.toFloat())
                }
            }
            .addOnCompleteListener {
                synchronized(lock) { isBusy = false }
                imageProxy.close()
            }
    }

    private fun processFace(
        face: Face,
        mappingMatrix: android.graphics.Matrix?,
        width: Float,
        height: Float
    ) {
        val mirrorX = isFrontCamera
        fun fx(x: Float): Float = if (mirrorX) width - x else x

        val leftEyeContour = face.getContour(FaceContour.LEFT_EYE)?.points
        val rightEyeContour = face.getContour(FaceContour.RIGHT_EYE)?.points
        val noseBridgeContour = face.getContour(FaceContour.NOSE_BRIDGE)?.points

        val rawLeftEye = if (!leftEyeContour.isNullOrEmpty()) {
            PointF(leftEyeContour.map { it.x }.average().toFloat(), leftEyeContour.map { it.y }.average().toFloat())
        } else {
            face.getLandmark(FaceLandmark.LEFT_EYE)?.position
        }

        val rawRightEye = if (!rightEyeContour.isNullOrEmpty()) {
            PointF(rightEyeContour.map { it.x }.average().toFloat(), rightEyeContour.map { it.y }.average().toFloat())
        } else {
            face.getLandmark(FaceLandmark.RIGHT_EYE)?.position
        }

        val rawNose = if (!noseBridgeContour.isNullOrEmpty()) {
            PointF(noseBridgeContour.map { it.x }.average().toFloat(), noseBridgeContour.map { it.y }.average().toFloat())
        } else {
            face.getLandmark(FaceLandmark.NOSE_BASE)?.position
                ?: PointF(face.boundingBox.centerX().toFloat(), face.boundingBox.top + face.boundingBox.height() * 0.55f)
        }

        val bounds: RectF
        val eyeMid: Offset
        val eyeDistance: Float
        var rollRad: Float
        var yawRad = Math.toRadians(-face.headEulerAngleY.toDouble()).toFloat()
        var pitchRad = Math.toRadians(face.headEulerAngleX.toDouble()).toFloat()
        val nose: Offset
        var mouthMid: Offset
        var rawMouthOpen = 0f
        val hasLandmarks: Boolean

        if (mappingMatrix != null) {
            val pts = floatArrayOf(
                rawLeftEye?.x ?: 0f, rawLeftEye?.y ?: 0f,
                rawRightEye?.x ?: 0f, rawRightEye?.y ?: 0f,
                rawNose.x, rawNose.y
            )
            mappingMatrix.mapPoints(pts)

            val p1 = if (rawLeftEye != null) Offset(pts[0], pts[1]) else null
            val p2 = if (rawRightEye != null) Offset(pts[2], pts[3]) else null
            nose = Offset(pts[4], pts[5])

            val screenBox = RectF(face.boundingBox)
            mappingMatrix.mapRect(screenBox)
            bounds = screenBox

            // Visual left has smaller X, visual right has larger X in screen coordinates
            val (screenLeft, screenRight) = if (p1 != null && p2 != null) {
                if (p1.x <= p2.x) Pair(p1, p2) else Pair(p2, p1)
            } else {
                Pair(p1 ?: p2, null)
            }

            hasLandmarks = screenLeft != null && screenRight != null

            eyeDistance = if (screenLeft != null && screenRight != null) {
                hypot(screenRight.x - screenLeft.x, screenRight.y - screenLeft.y).coerceAtLeast(1f)
            } else {
                (screenBox.width() * 0.44f).coerceAtLeast(1f)
            }

            rollRad = if (screenLeft != null && screenRight != null) {
                atan2(screenRight.y - screenLeft.y, screenRight.x - screenLeft.x)
            } else {
                Math.toRadians(if (mirrorX) face.headEulerAngleZ.toDouble() else -face.headEulerAngleZ.toDouble()).toFloat()
            }

            eyeMid = if (screenLeft != null && screenRight != null) {
                Offset((screenLeft.x + screenRight.x) / 2f, (screenLeft.y + screenRight.y) / 2f)
            } else {
                Offset(screenBox.centerX(), screenBox.top + screenBox.height() * 0.38f)
            }

            val upperLip = face.getContour(FaceContour.UPPER_LIP_BOTTOM)?.points
            val lowerLip = face.getContour(FaceContour.LOWER_LIP_TOP)?.points
            mouthMid = Offset(screenBox.centerX(), screenBox.top + screenBox.height() * 0.70f)

            if (!upperLip.isNullOrEmpty() && !lowerLip.isNullOrEmpty()) {
                val upperY = upperLip.map { it.y }.maxOrNull() ?: face.boundingBox.centerY().toFloat()
                val lowerY = lowerLip.map { it.y }.minOrNull() ?: face.boundingBox.centerY().toFloat()
                val mouthH = max(0f, lowerY - upperY)
                rawMouthOpen = ((mouthH / (face.boundingBox.width() * 0.25f) - 0.08f) / 0.38f).coerceIn(0f, 1f)

                val mPts = floatArrayOf(
                    (upperLip + lowerLip).map { it.x }.average().toFloat(),
                    (upperLip + lowerLip).map { it.y }.average().toFloat()
                )
                mappingMatrix.mapPoints(mPts)
                mouthMid = Offset(mPts[0], mPts[1])
            } else {
                val mouthBottom = face.getLandmark(FaceLandmark.MOUTH_BOTTOM)?.position
                val mouthLeft = face.getLandmark(FaceLandmark.MOUTH_LEFT)?.position
                val mouthRight = face.getLandmark(FaceLandmark.MOUTH_RIGHT)?.position
                if (mouthBottom != null && mouthLeft != null && mouthRight != null) {
                    val mPts = floatArrayOf((mouthLeft.x + mouthRight.x) / 2f, (mouthLeft.y + mouthRight.y) / 2f)
                    mappingMatrix.mapPoints(mPts)
                    mouthMid = Offset(mPts[0], mPts[1])
                    val lipDist = hypot(mouthLeft.x - mouthRight.x, mouthLeft.y - mouthRight.y)
                    rawMouthOpen = ((mouthBottom.y - (mouthLeft.y + mouthRight.y) / 2f) / (lipDist * 0.50f) - 0.10f).coerceIn(0f, 1f)
                }
            }

            if (mirrorX) {
                yawRad = -yawRad
            }
        } else {
            // Fallback when matrix is not yet initialized
            val rawBounds = RectF(face.boundingBox)
            bounds = if (mirrorX) {
                RectF(width - rawBounds.right, rawBounds.top, width - rawBounds.left, rawBounds.bottom)
            } else {
                rawBounds
            }

            val p1 = rawLeftEye?.let { Offset(fx(it.x), it.y) }
            val p2 = rawRightEye?.let { Offset(fx(it.x), it.y) }
            nose = Offset(fx(rawNose.x), rawNose.y)

            val (screenLeft, screenRight) = if (p1 != null && p2 != null) {
                if (p1.x <= p2.x) Pair(p1, p2) else Pair(p2, p1)
            } else {
                Pair(p1 ?: p2, null)
            }

            hasLandmarks = screenLeft != null && screenRight != null
            eyeDistance = if (screenLeft != null && screenRight != null) {
                hypot(screenRight.x - screenLeft.x, screenRight.y - screenLeft.y).coerceAtLeast(1f)
            } else {
                bounds.width() * 0.46f
            }

            rollRad = if (screenLeft != null && screenRight != null) {
                atan2(screenRight.y - screenLeft.y, screenRight.x - screenLeft.x)
            } else {
                Math.toRadians(if (mirrorX) face.headEulerAngleZ.toDouble() else -face.headEulerAngleZ.toDouble()).toFloat()
            }

            eyeMid = if (screenLeft != null && screenRight != null) {
                Offset((screenLeft.x + screenRight.x) / 2f, (screenLeft.y + screenRight.y) / 2f)
            } else {
                Offset(bounds.centerX(), bounds.top + bounds.height() * 0.40f)
            }

            mouthMid = Offset(bounds.centerX(), bounds.top + bounds.height() * 0.72f)
            val upperLip = face.getContour(FaceContour.UPPER_LIP_BOTTOM)?.points
            val lowerLip = face.getContour(FaceContour.LOWER_LIP_TOP)?.points
            if (!upperLip.isNullOrEmpty() && !lowerLip.isNullOrEmpty()) {
                val upperY = upperLip.map { it.y }.maxOrNull() ?: bounds.centerY()
                val lowerY = lowerLip.map { it.y }.minOrNull() ?: bounds.centerY()
                val mouthH = max(0f, lowerY - upperY)
                rawMouthOpen = ((mouthH / (eyeDistance * 0.42f) - 0.08f) / 0.38f).coerceIn(0f, 1f)
                val avgX = (upperLip + lowerLip).map { fx(it.x) }.average().toFloat()
                val avgY = (upperLip + lowerLip).map { it.y }.average().toFloat()
                mouthMid = Offset(avgX, avgY)
            }

            if (mirrorX) {
                rollRad = -rollRad
                yawRad = -yawRad
            }
        }

        val smiling = face.smilingProbability ?: 0f

        publish(
            width = width,
            height = height,
            bounds = bounds,
            eyeMid = eyeMid,
            eyeDistance = eyeDistance,
            roll = rollRad,
            yaw = yawRad,
            pitch = pitchRad,
            nose = nose,
            mouthMid = mouthMid,
            mouthOpen = rawMouthOpen,
            smile = smiling,
            hasLandmarks = hasLandmarks,
            isCanvasMapped = mappingMatrix != null
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

    fun DrawScope.drawFaceEffect(
        face: TrackedFace,
        effect: ClipFaceEffect,
        previewWidth: Float,
        previewHeight: Float,
        cameraSourceWidth: Float,
        cameraSourceHeight: Float,
        nowMs: Long = System.currentTimeMillis()
    ) {
        if (effect == ClipFaceEffect.NONE) return

        // Scale coordinates from camera source dimensions to preview container dimensions
        val scaleFactor = max(previewWidth / cameraSourceWidth, previewHeight / cameraSourceHeight)
        val offsetX = (previewWidth - cameraSourceWidth * scaleFactor) / 2f
        val offsetY = (previewHeight - cameraSourceHeight * scaleFactor) / 2f

        fun mapPoint(p: Offset): Offset {
            return Offset(p.x * scaleFactor + offsetX, p.y * scaleFactor + offsetY)
        }

        val D = if (face.isCanvasMapped) face.eyeDistance else face.eyeDistance * scaleFactor
        val eyeMid = if (face.isCanvasMapped) face.eyeMid else mapPoint(face.eyeMid)
        val nose = if (face.isCanvasMapped) face.nose else mapPoint(face.nose)
        val mouthMid = if (face.isCanvasMapped) face.mouthMid else mapPoint(face.mouthMid)

        val rollDeg = Math.toDegrees(face.roll.toDouble()).toFloat()
        val wobbleDeg = Math.toDegrees(face.earWobble.toDouble()).toFloat()

        // In screen coordinates (Y increases downwards):
        // Up towards the top of the screen is (sin(roll), -cos(roll)).
        // Right is (cos(roll), sin(roll)).
        val up = Offset(sin(face.roll), -cos(face.roll))
        val right = Offset(cos(face.roll), sin(face.roll))

        // 1. Primary Sprite (Headwear / Ears / Shades / Visor)
        val crownRise = when (effect) {
            ClipFaceEffect.DOG -> 0.58f
            ClipFaceEffect.TIGER -> 0.56f
            ClipFaceEffect.PARTY -> 0.68f
            ClipFaceEffect.BUNNY -> 0.62f
            ClipFaceEffect.KOALA -> 0.54f
            ClipFaceEffect.CAT -> 0.58f
            ClipFaceEffect.CROWN -> 0.65f
            ClipFaceEffect.HALO -> 1.02f
            ClipFaceEffect.DEVIL -> 0.58f
            else -> 0.0f
        }

        var headAnchor = if (effect.isEyewear) {
            Offset(
                eyeMid.x + right.x * (D * sin(face.yaw) * 0.15f),
                eyeMid.y + right.y * (D * sin(face.yaw) * 0.15f)
            )
        } else {
            Offset(
                eyeMid.x + up.x * (D * crownRise) + right.x * (D * sin(face.yaw) * 0.20f),
                eyeMid.y + up.y * (D * crownRise) + right.y * (D * sin(face.yaw) * 0.20f)
            )
        }

        if (effect == ClipFaceEffect.HALO) {
            val bob = sin(nowMs / 250f) * (D * 0.06f)
            headAnchor = Offset(headAnchor.x + up.x * bob, headAnchor.y + up.y * bob)
        }

        val headScale = when (effect) {
            ClipFaceEffect.DOG -> D * 1.85f / 512f
            ClipFaceEffect.TIGER -> D * 1.75f / 512f
            ClipFaceEffect.PARTY -> D * 1.45f / 512f
            ClipFaceEffect.CYBER -> D * 1.65f / 512f
            ClipFaceEffect.BUNNY -> D * 1.65f / 512f
            ClipFaceEffect.KOALA -> D * 1.80f / 512f
            ClipFaceEffect.CAT -> D * 1.65f / 512f
            ClipFaceEffect.SUNGLASSES -> D * 1.60f / 512f
            ClipFaceEffect.CROWN -> D * 1.60f / 512f
            ClipFaceEffect.HALO -> D * 1.80f / 512f
            ClipFaceEffect.DEVIL -> D * 1.60f / 512f
            ClipFaceEffect.NONE -> 0f
        }

        val earAngle = if (effect == ClipFaceEffect.DOG || effect == ClipFaceEffect.BUNNY ||
            effect == ClipFaceEffect.TIGER || effect == ClipFaceEffect.CAT || effect == ClipFaceEffect.KOALA) {
            rollDeg + wobbleDeg
        } else {
            rollDeg
        }

        translate(left = headAnchor.x, top = headAnchor.y) {
            rotate(degrees = earAngle) {
                scale(scaleX = headScale * cos(face.yaw).coerceAtLeast(0.50f), scaleY = headScale) {
                    translate(left = -256f, top = -256f) {
                        drawMainHeadwear(effect)
                    }
                }
            }
        }

        // 2. Nose Sprite (Snout / Feline nose)
        if (effect == ClipFaceEffect.DOG || effect == ClipFaceEffect.BUNNY ||
            effect == ClipFaceEffect.KOALA || effect == ClipFaceEffect.CAT || effect == ClipFaceEffect.TIGER) {
            val noseScale = (D * 0.42f) / 512f
            translate(left = nose.x, top = nose.y) {
                rotate(degrees = rollDeg) {
                    scale(scaleX = noseScale * cos(face.yaw).coerceAtLeast(0.60f), scaleY = noseScale) {
                        translate(left = -256f, top = -256f) {
                            drawNose(effect)
                        }
                    }
                }
            }
        }

        // 3. Face Details (Whiskers, Tiger stripes, Cyber HUD)
        if (effect == ClipFaceEffect.CYBER) {
            val hudScale = (D * 1.55f) / 512f
            translate(left = eyeMid.x, top = eyeMid.y) {
                rotate(degrees = rollDeg) {
                    scale(scaleX = hudScale * cos(face.yaw).coerceAtLeast(0.60f), scaleY = hudScale) {
                        translate(left = -256f, top = -256f) {
                            drawFaceDetails(effect)
                        }
                    }
                }
            }
        } else if (effect == ClipFaceEffect.CAT || effect == ClipFaceEffect.BUNNY ||
            effect == ClipFaceEffect.TIGER || effect == ClipFaceEffect.PARTY) {
            val detailScale = (D * 1.60f) / 512f
            translate(left = nose.x, top = nose.y) {
                rotate(degrees = rollDeg) {
                    scale(scaleX = detailScale * cos(face.yaw).coerceAtLeast(0.60f), scaleY = detailScale) {
                        translate(left = -256f, top = -256f) {
                            drawFaceDetails(effect)
                        }
                    }
                }
            }
        }

        // 4. Reactive Mouth Action Units (Tongue, Fangs, Confetti)
        if (effect.hasReactiveMouth) {
            if (effect == ClipFaceEffect.DOG && face.mouthOpenness > 0.15f) {
                val openProg = ((face.mouthOpenness - 0.15f) / 0.45f).coerceIn(0f, 1f)
                val tongueScaleX = (D * 0.55f) / 512f
                val tongueScaleY = (D * 0.90f * openProg) / 512f

                translate(left = mouthMid.x, top = mouthMid.y) {
                    rotate(degrees = rollDeg + wobbleDeg * 0.3f) {
                        scale(scaleX = tongueScaleX, scaleY = tongueScaleY) {
                            translate(left = -256f, top = 0f) {
                                drawDogTongue()
                            }
                        }
                    }
                }
            } else if (effect == ClipFaceEffect.TIGER && face.mouthOpenness > 0.18f) {
                val openProg = ((face.mouthOpenness - 0.18f) / 0.40f).coerceIn(0f, 1f)
                val fScale = (D * 0.65f) / 512f

                translate(left = mouthMid.x, top = mouthMid.y) {
                    rotate(degrees = rollDeg) {
                        scale(scaleX = fScale, scaleY = fScale * openProg) {
                            translate(left = -256f, top = -60f) {
                                drawTigerFangs()
                            }
                        }
                    }
                }
            } else if (effect == ClipFaceEffect.PARTY && (face.mouthOpenness > 0.22f || face.smilingRatio > 0.40f)) {
                val burstScale = (D * 2.3f) / 512f
                translate(left = mouthMid.x, top = mouthMid.y) {
                    rotate(degrees = rollDeg) {
                        scale(scaleX = burstScale, scaleY = burstScale) {
                            translate(left = -256f, top = -256f) {
                                drawPartyConfetti(nowMs)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Artwork Renderers (512x512 canvas coordinate space)

    private fun DrawScope.drawMainHeadwear(effect: ClipFaceEffect) {
        when (effect) {
            ClipFaceEffect.DOG -> drawDogEars()
            ClipFaceEffect.BUNNY -> drawBunnyEars()
            ClipFaceEffect.KOALA -> drawKoalaEars()
            ClipFaceEffect.CAT -> drawCatEars()
            ClipFaceEffect.TIGER -> drawTigerEars()
            ClipFaceEffect.SUNGLASSES -> drawSunglasses()
            ClipFaceEffect.CROWN -> drawCrown()
            ClipFaceEffect.HALO -> drawHalo()
            ClipFaceEffect.DEVIL -> drawDevilHorns()
            ClipFaceEffect.PARTY -> drawPartyHat()
            ClipFaceEffect.CYBER -> drawCyberVisor()
            ClipFaceEffect.NONE -> {}
        }
    }

    private fun DrawScope.drawKoalaEars() {
        val earGrey = Color(0xFF6B7280)
        val outerFluff = Color(0xFF8C939E)
        val innerPink = Color(0xFFF6BAC2)

        fun oneEar() {
            // Fluffy outer lobes (situated towards the outside)
            drawCircle(outerFluff, radius = 70f, center = Offset(135f, 165f))
            drawCircle(outerFluff, radius = 34f, center = Offset(75f, 140f))
            drawCircle(outerFluff, radius = 36f, center = Offset(80f, 190f))
            drawCircle(outerFluff, radius = 30f, center = Offset(110f, 230f))
            drawCircle(outerFluff, radius = 28f, center = Offset(170f, 115f))

            // Main grey ear base
            drawCircle(earGrey, radius = 62f, center = Offset(135f, 165f))

            // Soft pink inner ear
            drawCircle(innerPink, radius = 42f, center = Offset(135f, 165f))

            // Soft inner tuft towards the head
            drawCircle(Color.White.copy(alpha = 0.50f), radius = 18f, center = Offset(160f, 165f))
        }

        oneEar()
        scale(scaleX = -1f, scaleY = 1f, pivot = Offset(256f, 256f)) {
            oneEar()
        }
    }

    private fun DrawScope.drawCatEars() {
        val darkFur = Color(0xFF2C2F38)
        val pinkInner = Color(0xFFF8A5B2)

        fun oneEar() {
            val outerPath = Path().apply {
                moveTo(225f, 250f)
                cubicTo(205f, 210f, 160f, 110f, 125f, 85f)
                cubicTo(115f, 78f, 105f, 88f, 102f, 100f)
                cubicTo(92f, 145f, 82f, 210f, 75f, 250f)
                close()
            }
            drawPath(outerPath, darkFur)

            val innerPath = Path().apply {
                moveTo(205f, 240f)
                cubicTo(190f, 205f, 155f, 130f, 126f, 108f)
                cubicTo(120f, 115f, 105f, 165f, 100f, 240f)
                close()
            }
            drawPath(innerPath, pinkInner)

            drawCircle(Color.White.copy(alpha = 0.8f), radius = 14f, center = Offset(135f, 240f))
        }

        oneEar()
        scale(scaleX = -1f, scaleY = 1f, pivot = Offset(256f, 256f)) {
            oneEar()
        }
    }

    private fun DrawScope.drawDogEars() {
        val brownFur = Color(0xFF7A4A28)
        val tanInner = Color(0xFFC9976D)

        fun oneEar() {
            val outerPath = Path().apply {
                moveTo(195f, 235f)
                cubicTo(135f, 235f, 65f, 285f, 60f, 365f)
                cubicTo(55f, 435f, 125f, 445f, 175f, 375f)
                cubicTo(200f, 340f, 215f, 280f, 210f, 240f)
                close()
            }
            drawPath(outerPath, brownFur)

            val innerPath = Path().apply {
                moveTo(180f, 250f)
                cubicTo(140f, 255f, 95f, 305f, 92f, 365f)
                cubicTo(90f, 415f, 140f, 420f, 168f, 370f)
                cubicTo(185f, 340f, 195f, 290f, 192f, 255f)
                close()
            }
            drawPath(innerPath, tanInner)
        }

        oneEar()
        scale(scaleX = -1f, scaleY = 1f, pivot = Offset(256f, 256f)) {
            oneEar()
        }
    }

    private fun DrawScope.drawTigerEars() {
        val orange = Color(0xFFF39C12)
        val blackStripe = Color(0xFF1E1E24)
        val whiteFur = Color(0xFFFDFEFE)
        val pinkInner = Color(0xFFF8A5B2)

        fun oneEar() {
            val outerPath = Path().apply {
                moveTo(230f, 248f)
                cubicTo(210f, 125f, 120f, 95f, 85f, 248f)
                close()
            }
            drawPath(outerPath, orange)

            val whiteTrim = Path().apply {
                moveTo(215f, 245f)
                cubicTo(198f, 145f, 130f, 120f, 105f, 245f)
                close()
            }
            drawPath(whiteTrim, whiteFur)

            val innerPath = Path().apply {
                moveTo(200f, 240f)
                cubicTo(188f, 160f, 142f, 140f, 122f, 240f)
                close()
            }
            drawPath(innerPath, pinkInner)

            val s1 = Path().apply { moveTo(140f, 115f); lineTo(160f, 165f) }
            val s2 = Path().apply { moveTo(175f, 125f); lineTo(190f, 180f) }
            drawPath(s1, blackStripe, style = Stroke(width = 10f, cap = StrokeCap.Round))
            drawPath(s2, blackStripe, style = Stroke(width = 10f, cap = StrokeCap.Round))
        }

        oneEar()
        scale(scaleX = -1f, scaleY = 1f, pivot = Offset(256f, 256f)) {
            oneEar()
        }
    }

    private fun DrawScope.drawBunnyEars() {
        val whiteFur = Color(0xFFF8F9FA)
        val pinkInner = Color(0xFFF9A8B8)

        fun oneEar() {
            val outerPath = Path().apply {
                moveTo(210f, 248f)
                cubicTo(175f, 190f, 145f, 40f, 170f, 25f)
                cubicTo(205f, 15f, 235f, 115f, 238f, 240f)
                close()
            }
            drawPath(outerPath, whiteFur)

            val innerPath = Path().apply {
                moveTo(206f, 235f)
                cubicTo(180f, 180f, 160f, 75f, 176f, 60f)
                cubicTo(196f, 50f, 220f, 125f, 222f, 230f)
                close()
            }
            drawPath(innerPath, pinkInner)
        }

        oneEar()
        scale(scaleX = -1f, scaleY = 1f, pivot = Offset(256f, 256f)) {
            oneEar()
        }
    }

    private fun DrawScope.drawCrown() {
        val crown = Path().apply {
            moveTo(80f, 390f)
            lineTo(60f, 150f)
            lineTo(150f, 265f)
            lineTo(195f, 110f)
            lineTo(256f, 235f)
            lineTo(256f, 50f)
            lineTo(256f, 235f)
            lineTo(317f, 110f)
            lineTo(362f, 265f)
            lineTo(452f, 150f)
            lineTo(432f, 390f)
            close()
        }
        drawPath(crown, Color(0xFFF9CA24))

        // Headband trim
        drawRoundRect(
            color = Color(0xFFD4AC0D),
            topLeft = Offset(75f, 370f),
            size = Size(362f, 50f),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(12f, 12f)
        )

        // Ruby Gems
        val ruby = Color(0xFFEB2F06)
        drawCircle(ruby, radius = 20f, center = Offset(256f, 75f))
        drawCircle(ruby, radius = 15f, center = Offset(195f, 130f))
        drawCircle(ruby, radius = 15f, center = Offset(317f, 130f))
        drawCircle(ruby, radius = 12f, center = Offset(55f, 170f))
        drawCircle(ruby, radius = 12f, center = Offset(457f, 170f))
        drawCircle(ruby, radius = 18f, center = Offset(256f, 395f))
    }

    private fun DrawScope.drawSunglasses() {
        val black = Color(0xFF19191C)
        val lensColor = Color(0xFF1E3799)

        // Outer frames
        drawRoundRect(black, topLeft = Offset(40f, 165f), size = Size(200f, 185f), cornerRadius = androidx.compose.ui.geometry.CornerRadius(60f, 60f))
        drawRoundRect(black, topLeft = Offset(272f, 165f), size = Size(200f, 185f), cornerRadius = androidx.compose.ui.geometry.CornerRadius(60f, 60f))
        // Bridge
        drawRoundRect(black, topLeft = Offset(220f, 215f), size = Size(72f, 40f), cornerRadius = androidx.compose.ui.geometry.CornerRadius(10f, 10f))

        // Lenses
        drawRoundRect(lensColor, topLeft = Offset(60f, 185f), size = Size(160f, 145f), cornerRadius = androidx.compose.ui.geometry.CornerRadius(45f, 45f))
        drawRoundRect(lensColor, topLeft = Offset(292f, 185f), size = Size(160f, 145f), cornerRadius = androidx.compose.ui.geometry.CornerRadius(45f, 45f))

        // Glare streak
        val glare = Path().apply {
            moveTo(80f, 310f); lineTo(160f, 190f); lineTo(185f, 190f); lineTo(105f, 310f); close()
            moveTo(310f, 310f); lineTo(390f, 190f); lineTo(415f, 190f); lineTo(335f, 310f); close()
        }
        drawPath(glare, Color.White.copy(alpha = 0.35f))
    }

    private fun DrawScope.drawCyberVisor() {
        val visor = Path().apply {
            moveTo(40f, 195f)
            lineTo(110f, 175f)
            lineTo(402f, 175f)
            lineTo(472f, 195f)
            lineTo(450f, 315f)
            lineTo(300f, 335f)
            lineTo(256f, 275f)
            lineTo(212f, 335f)
            lineTo(62f, 315f)
            close()
        }
        drawPath(visor, Color(0xDD0A0E1A))
        drawPath(visor, Color(0xFF00F0FF), style = Stroke(width = 8f, join = StrokeJoin.Miter))

        // Grid lines
        for (y in 190..310 step 25) {
            drawLine(
                color = Color(0x5500F0FF),
                start = Offset(60f, y.toFloat()),
                end = Offset(452f, y.toFloat()),
                strokeWidth = 2f
            )
        }

        // Crosshair HUD
        drawCircle(Color(0xFFFF007F), radius = 30f, center = Offset(365f, 245f), style = Stroke(width = 4f))
        drawLine(Color(0xFFFF007F), start = Offset(325f, 245f), end = Offset(405f, 245f), strokeWidth = 3f)
        drawLine(Color(0xFFFF007F), start = Offset(365f, 205f), end = Offset(365f, 285f), strokeWidth = 3f)

        // Glare streak
        val glare = Path().apply {
            moveTo(90f, 305f); lineTo(160f, 185f); lineTo(180f, 185f); lineTo(110f, 305f); close()
        }
        drawPath(glare, Color.White.copy(alpha = 0.40f))
    }

    private fun DrawScope.drawHalo() {
        drawOval(
            color = Color(0xFFF9CA24),
            topLeft = Offset(75f, 180f),
            size = Size(362f, 145f),
            style = Stroke(width = 30f)
        )
        drawOval(
            color = Color.White.copy(alpha = 0.85f),
            topLeft = Offset(80f, 185f),
            size = Size(352f, 135f),
            style = Stroke(width = 12f)
        )
    }

    private fun DrawScope.drawDevilHorns() {
        fun horn(flipped: Boolean) {
            val h = Path().apply {
                moveTo(165f, 315f)
                cubicTo(110f, 265f, 70f, 160f, 70f, 80f)
                cubicTo(100f, 110f, 160f, 200f, 205f, 280f)
                close()
            }
            val ridge = Path().apply {
                moveTo(155f, 295f)
                cubicTo(115f, 245f, 80f, 170f, 80f, 100f)
                cubicTo(105f, 140f, 145f, 220f, 175f, 275f)
                close()
            }
            if (flipped) {
                scale(scaleX = -1f, scaleY = 1f, pivot = Offset(256f, 256f)) {
                    drawPath(h, Color(0xFFE71C23))
                    drawPath(ridge, Color(0xFFFF5722))
                }
            } else {
                drawPath(h, Color(0xFFE71C23))
                drawPath(ridge, Color(0xFFFF5722))
            }
        }
        horn(flipped = false)
        horn(flipped = true)
    }

    private fun DrawScope.drawPartyHat() {
        val cone = Path().apply {
            moveTo(256f, 60f)
            lineTo(110f, 400f)
            quadraticTo(256f, 440f, 402f, 400f)
            close()
        }
        drawPath(cone, Color(0xFFF9CA24))

        // Stripes
        val colors = listOf(Color(0xFFFF3F34), Color(0xFF00F0FF), Color(0xFF9B59B6))
        for (i in 0..3) {
            val y = 140f + i * 65f
            drawLine(
                color = colors[i % colors.size],
                start = Offset(130f + i * 20f, y),
                end = Offset(380f - i * 20f, y - 45f),
                strokeWidth = 24f
            )
        }

        // Pom pom
        drawCircle(Color(0xFFFF3F34), radius = 35f, center = Offset(256f, 55f))
        drawCircle(Color.White, radius = 10f, center = Offset(250f, 50f))
    }

    private fun DrawScope.drawNose(effect: ClipFaceEffect) {
        when (effect) {
            ClipFaceEffect.KOALA -> {
                // Large vertical charcoal-black rounded oval button nose
                drawRoundRect(
                    color = Color(0xFF23252B),
                    topLeft = Offset(196f, 145f),
                    size = Size(120f, 185f),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(60f, 75f)
                )
                // Soft specular light highlight
                drawOval(
                    color = Color.White.copy(alpha = 0.28f),
                    topLeft = Offset(215f, 170f),
                    size = Size(36f, 60f)
                )
            }
            ClipFaceEffect.DOG -> {
                // Cute dog nose with nostrils
                val nosePath = Path().apply {
                    moveTo(256f, 320f)
                    cubicTo(160f, 310f, 130f, 210f, 160f, 180f)
                    cubicTo(195f, 150f, 317f, 150f, 352f, 180f)
                    cubicTo(382f, 210f, 352f, 310f, 256f, 320f)
                    close()
                }
                drawPath(nosePath, Color(0xFF1E1E24))
                // Nostrils
                drawCircle(Color(0xFF0F0F12), radius = 16f, center = Offset(215f, 260f))
                drawCircle(Color(0xFF0F0F12), radius = 16f, center = Offset(297f, 260f))
                // Specular sheen
                drawCircle(Color.White.copy(alpha = 0.35f), radius = 20f, center = Offset(215f, 205f))
            }
            ClipFaceEffect.CAT, ClipFaceEffect.TIGER, ClipFaceEffect.BUNNY -> {
                // Delicate pink inverted rounded nose
                val catNose = Path().apply {
                    moveTo(256f, 290f)
                    cubicTo(205f, 280f, 175f, 220f, 205f, 195f)
                    cubicTo(225f, 180f, 287f, 180f, 307f, 195f)
                    cubicTo(337f, 220f, 307f, 280f, 256f, 290f)
                    close()
                }
                drawPath(catNose, Color(0xFFF9A8B8))
                drawCircle(Color.White.copy(alpha = 0.40f), radius = 15f, center = Offset(235f, 210f))
            }
            else -> {}
        }
    }

    private fun DrawScope.drawFaceDetails(effect: ClipFaceEffect) {
        when (effect) {
            ClipFaceEffect.CAT -> {
                // Pink blush cheeks
                drawOval(Color(0x44FF78A5), topLeft = Offset(40f, 215f), size = Size(125f, 80f))
                drawOval(Color(0x44FF78A5), topLeft = Offset(347f, 215f), size = Size(125f, 80f))
                // Whiskers
                val wColor = Color.White.copy(alpha = 0.90f)
                drawLine(wColor, start = Offset(160f, 245f), end = Offset(10f, 215f), strokeWidth = 5f, cap = StrokeCap.Round)
                drawLine(wColor, start = Offset(150f, 280f), end = Offset(20f, 295f), strokeWidth = 5f, cap = StrokeCap.Round)
                drawLine(wColor, start = Offset(352f, 245f), end = Offset(502f, 215f), strokeWidth = 5f, cap = StrokeCap.Round)
                drawLine(wColor, start = Offset(362f, 280f), end = Offset(492f, 295f), strokeWidth = 5f, cap = StrokeCap.Round)
            }
            ClipFaceEffect.TIGER -> {
                // Bold black tiger stripes on cheeks
                val black = Color(0xEE1E1E24)
                fun stripe(sx: Float, sy: Float, ex: Float, ey: Float) {
                    val p = Path().apply {
                        moveTo(sx, sy)
                        quadraticTo((sx + ex) / 2f, (sy + ey) / 2f + 15f, ex, ey)
                        quadraticTo((sx + ex) / 2f, (sy + ey) / 2f + 25f, sx, sy + 18f)
                        close()
                    }
                    drawPath(p, black)
                }
                stripe(20f, 205f, 130f, 235f)
                stripe(30f, 265f, 135f, 285f)
                stripe(50f, 325f, 125f, 335f)

                stripe(492f, 205f, 382f, 235f)
                stripe(482f, 265f, 377f, 285f)
                stripe(462f, 325f, 387f, 335f)
            }
            ClipFaceEffect.BUNNY -> {
                drawOval(Color(0x55FF9EB5), topLeft = Offset(60f, 230f), size = Size(115f, 75f))
                drawOval(Color(0x55FF9EB5), topLeft = Offset(337f, 230f), size = Size(115f, 75f))
            }
            ClipFaceEffect.PARTY -> {
                val gold = Color(0xFFF9CA24)
                drawCircle(gold, radius = 12f, center = Offset(90f, 250f))
                drawCircle(gold, radius = 8f, center = Offset(130f, 220f))
                drawCircle(gold, radius = 12f, center = Offset(422f, 250f))
                drawCircle(gold, radius = 8f, center = Offset(382f, 220f))
            }
            ClipFaceEffect.CYBER -> {
                val cyan = Color(0xFF00F0FF)
                drawRect(cyan, topLeft = Offset(60f, 215f), size = Size(40f, 5f))
                drawRect(cyan, topLeft = Offset(60f, 215f), size = Size(5f, 40f))
                drawRect(cyan, topLeft = Offset(412f, 215f), size = Size(40f, 5f))
                drawRect(cyan, topLeft = Offset(447f, 215f), size = Size(5f, 40f))
                drawCircle(Color(0xFFFF007F), radius = 6f, center = Offset(105f, 275f))
                drawCircle(Color(0xFFFF007F), radius = 6f, center = Offset(407f, 275f))
            }
            else -> {}
        }
    }

    private fun DrawScope.drawDogTongue() {
        val tongue = Path().apply {
            moveTo(130f, 10f)
            lineTo(115f, 360f)
            cubicTo(115f, 500f, 397f, 500f, 397f, 360f)
            lineTo(382f, 10f)
            close()
        }
        drawPath(tongue, Color(0xFFFF6B8B))

        // Center cleft
        drawLine(
            color = Color(0xFFD63031).copy(alpha = 0.75f),
            start = Offset(256f, 50f),
            end = Offset(256f, 350f),
            strokeWidth = 14f,
            cap = StrokeCap.Round
        )
        // Specular shine
        drawOval(
            color = Color.White.copy(alpha = 0.45f),
            topLeft = Offset(155f, 150f),
            size = Size(70f, 140f)
        )
    }

    private fun DrawScope.drawTigerFangs() {
        fun fang(xc: Float, flipped: Boolean) {
            val f = Path().apply {
                val dx = if (flipped) -1f else 1f
                moveTo(xc - 35f * dx, 50f)
                cubicTo(xc - 15f * dx, 225f, xc - 6f * dx, 350f, xc + 6f * dx, 440f)
                cubicTo(xc + 15f * dx, 325f, xc + 25f * dx, 175f, xc + 35f * dx, 50f)
                close()
            }
            drawPath(f, Color.White)
            drawPath(f, Color(0x551E1E24), style = Stroke(width = 4f))
        }
        fang(xc = 165f, flipped = false)
        fang(xc = 347f, flipped = true)
    }

    private fun DrawScope.drawPartyConfetti(nowMs: Long) {
        val colors = listOf(Color(0xFFF9CA24), Color(0xFFFF3F34), Color(0xFF00F0FF), Color(0xFF9B59B6), Color(0xFF2ED573))
        val offsets = listOf(
            Offset(100f, 130f), Offset(410f, 110f),
            Offset(60f, 310f), Offset(450f, 280f),
            Offset(180f, 60f), Offset(330f, 50f),
            Offset(130f, 420f), Offset(380f, 430f),
            Offset(40f, 190f), Offset(470f, 180f),
            Offset(200f, 470f), Offset(310f, 480f)
        )

        for (i in offsets.indices) {
            val color = colors[i % colors.size]
            val pt = offsets[i]
            val isStar = i % 2 == 0

            if (isStar) {
                val star = Path().apply {
                    val r = 24f
                    moveTo(pt.x, pt.y - r)
                    quadraticTo(pt.x + r * 0.2f, pt.y - r * 0.2f, pt.x + r, pt.y)
                    quadraticTo(pt.x + r * 0.2f, pt.y + r * 0.2f, pt.x, pt.y + r)
                    quadraticTo(pt.x - r * 0.2f, pt.y + r * 0.2f, pt.x - r, pt.y)
                    quadraticTo(pt.x - r * 0.2f, pt.y - r * 0.2f, pt.x, pt.y - r)
                    close()
                }
                drawPath(star, color)
            } else {
                drawRoundRect(
                    color = color,
                    topLeft = Offset(pt.x - 10f, pt.y - 18f),
                    size = Size(20f, 36f),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(6f, 6f)
                )
            }
        }
    }
}

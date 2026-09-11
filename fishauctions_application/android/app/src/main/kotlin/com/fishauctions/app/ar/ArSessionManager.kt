package com.fishauctions.app.ar

import android.app.Activity
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.Image
import android.os.Build
import android.util.Log
import android.view.Surface
import com.google.ar.core.ArCoreApk
import com.google.ar.core.CameraConfig
import com.google.ar.core.CameraConfigFilter
import com.google.ar.core.Config
import com.google.ar.core.Frame
import com.google.ar.core.Session
import com.google.ar.core.TrackingFailureReason
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.CameraNotAvailableException
import com.google.ar.core.exceptions.NotYetAvailableException
import com.google.ar.core.exceptions.UnavailableException
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage

/**
 * Owns one ARCore [Session]: availability/install, lifecycle, the per-frame update, and pose +
 * QR-detection extraction. Everything Dart cares about (the odometry channel in
 * BACKEND_SPEC.md Part 5, plus QR sightings) comes out through [PoseListener]/
 * [DetectionListener], which `ArCameraPlatformView` forwards over EventChannels.
 *
 * ARCore must own the camera to do visual-inertial tracking (that's what VIO *is* — camera +
 * IMU fused), so this replaces the mobile_scanner/CameraX pipeline entirely for AR mode rather
 * than running alongside it: Android doesn't support two independent clients opening the same
 * camera concurrently, and CameraX has no supported path into ARCore's own "shared camera"
 * mechanism. QR detection moves to ML Kit fed by ARCore's frames — the same underlying engine
 * mobile_scanner already used, so detection quality shouldn't regress.
 *
 * **Two threads.** [ensureSession], [resume], [pause] and [close] run on the UI thread;
 * [update], [setCameraTextureName] and [setDisplayGeometry] on the GL render thread. The view
 * pauses the GL thread before any UI-thread call that replaces or closes the session, so the
 * two never touch one session at once. Anything thrown on the GL thread ends the process, so
 * nothing there may escape.
 */
class ArSessionManager(private val activity: Activity) {
    interface PoseListener {
        /** [tracking] false means the pose is unreliable right now — callers should hold their
         * last known odometry/yaw rather than jump to a stale/garbage value. [px]/[pz] are the
         * pose's world-frame horizontal translation (meters); [fx]/[fz] the horizontal
         * components of the camera's forward direction (unit-ish, not normalized) — both in
         * ARCore's own arbitrary session-fixed world frame. The Dart side (ar_geometry.dart)
         * derives yaw and the BACKEND_SPEC.md Part 5 odometry frame from these via a verified,
         * unit-tested transform — deliberately no trig happens natively here. */
        fun onPose(tracking: Boolean, px: Float, pz: Float, fx: Float, fz: Float)
    }

    interface DetectionListener {
        fun onDetections(imageWidth: Int, imageHeight: Int, barcodes: List<DetectedBarcode>)
    }

    interface StatusListener {
        /** One of "checking", "unsupported", "installing", "ready", "error". */
        fun onStatus(status: String, message: String?)
    }

    data class DetectedBarcode(val rawValue: String?, val corners: List<FloatArray>)

    var poseListener: PoseListener? = null
    var detectionListener: DetectionListener? = null
    var statusListener: StatusListener? = null

    @Volatile private var session: Session? = null
    private var installRequested = false

    /** True while ARCore is still working out whether this device is supported — the usual
     * answer to the first check of a process. The view asks again shortly. */
    var availabilityPending = false
        private set

    // GL-thread state. The camera texture and display geometry belong to the GL surface, not to
    // a session, and a session can be created after the surface exists: the availability check
    // or the ARCore installer finishing on a later resume. So they're recorded here and handed
    // to whichever session [update] finds. They used to be handed over once, at surface
    // creation — to a session that might not exist yet — and ARCore's update() throws for a
    // session that was never given a texture, on the GL thread, which kills the app.
    private var cameraTextureId = -1
    private var textureAppliedTo: Session? = null
    private var geometryRotation = Surface.ROTATION_0
    private var geometryWidth = 0
    private var geometryHeight = 0
    private var geometryAppliedTo: Session? = null
    private var lastUpdateError: String? = null
    private var reportedCameraLoss = false

    private val barcodeScanner = BarcodeScanning.getClient(
        BarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .build(),
    )
    @Volatile private var detectionInFlight = false
    private var lastDetectionAttemptMs = 0L
    private val detectionIntervalMs = 100L // ~10 Hz — plenty for a hand-held scan sweep

    /** The back camera's mounting angle. Asked once: it was a CameraManager IPC ten times a
     * second, for a value that can't change. */
    private val sensorOrientation: Int by lazy { backCameraSensorOrientation(activity) }

    /** Creates and configures the session if needed. Returns true when a session is ready to
     * [resume]. False (with [statusListener] told why) means AR mode can't proceed yet — or, with
     * [availabilityPending], can't tell yet. */
    fun ensureSession(): Boolean {
        if (session != null) {
            return true
        }
        statusListener?.onStatus("checking", null)
        try {
            val availability = ArCoreApk.getInstance().checkAvailability(activity)
            availabilityPending = availability.isTransient
            if (availability.isTransient) {
                // The network check is still in flight. The view retries shortly rather than
                // blocking here (ArCameraPlatformView.startSession).
                return false
            }
            if (!availability.isSupported) {
                statusListener?.onStatus(
                    "unsupported",
                    "This device doesn't support ARCore, which AR lot mode needs for camera tracking.",
                )
                return false
            }
            when (ArCoreApk.getInstance().requestInstall(activity, !installRequested)) {
                ArCoreApk.InstallStatus.INSTALL_REQUESTED -> {
                    // Google Play Services for AR is installing/updating — the Activity is about
                    // to pause for that flow. The view re-calls ensureSession() on resume.
                    installRequested = true
                    statusListener?.onStatus("installing", null)
                    return false
                }
                ArCoreApk.InstallStatus.INSTALLED -> Unit
            }
        } catch (e: UnavailableException) {
            statusListener?.onStatus("error", e.message ?: e.toString())
            return false
        }

        return try {
            val newSession = Session(activity)
            val config = Config(newSession).apply {
                // Pose tracking is all AR lot mode needs — everything else costs CPU/battery for
                // nothing this feature uses.
                planeFindingMode = Config.PlaneFindingMode.DISABLED
                lightEstimationMode = Config.LightEstimationMode.DISABLED
                depthMode = Config.DepthMode.DISABLED
                focusMode = Config.FocusMode.AUTO
                updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
            }
            newSession.configure(config)
            selectCpuImageCameraConfig(newSession)
            session = newSession
            reportedCameraLoss = false
            statusListener?.onStatus("ready", null)
            true
        } catch (e: UnavailableException) {
            statusListener?.onStatus("error", e.message ?: e.toString())
            false
        } catch (e: Exception) {
            statusListener?.onStatus("error", e.message ?: e.toString())
            false
        }
    }

    /** Prefers a camera config that also exposes a CPU (YUV) image stream — the one
     * [Frame.acquireCameraImage] reads for ML Kit — over ARCore's default, which on some devices
     * only enables the GPU texture stream. Falls back to the default silently if no such config
     * is offered (detection then simply never gets an image; tracking is unaffected). */
    private fun selectCpuImageCameraConfig(session: Session) {
        try {
            val filter = CameraConfigFilter(session)
                .setFacingDirection(CameraConfig.FacingDirection.BACK)
            val configs = session.getSupportedCameraConfigs(filter)
            val withCpuImage = configs.firstOrNull { it.imageSize.width > 0 }
            if (withCpuImage != null) {
                session.cameraConfig = withCpuImage
            }
        } catch (e: Exception) {
            Log.w(TAG, "camera config selection failed, using ARCore default", e)
        }
    }

    /** UI thread, with the GL thread paused. Runs from Activity.onResume, so an exception here
     * would crash the app on the way back into it — every failure becomes an explainer instead. */
    fun resume() {
        val s = session ?: return
        try {
            s.resume()
        } catch (e: CameraNotAvailableException) {
            discard(s, "Camera is in use by another app. Go back and try again.")
        } catch (e: Exception) {
            Log.w(TAG, "AR session failed to resume", e)
            discard(s, "Lot scanning couldn't start the camera. Go back and try again.")
        }
    }

    /** Closes a session that can't run. It used to be dropped without closing, which leaked its
     * native memory and left a second session to contend with it on the next resume. */
    private fun discard(s: Session, message: String) {
        session = null
        try {
            s.close()
        } catch (e: Exception) {
            Log.w(TAG, "AR session close failed", e)
        }
        statusListener?.onStatus("error", message)
    }

    fun pause() {
        try {
            session?.pause()
        } catch (e: Exception) {
            Log.w(TAG, "AR session pause failed", e)
        }
    }

    fun close() {
        val s = session
        session = null
        try {
            s?.close()
        } catch (e: Exception) {
            Log.w(TAG, "AR session close failed", e)
        }
        barcodeScanner.close()
    }

    /** GL thread. Applied to the session on the next [update]. */
    fun setDisplayGeometry(rotation: Int, width: Int, height: Int) {
        geometryRotation = rotation
        geometryWidth = width
        geometryHeight = height
        geometryAppliedTo = null
    }

    /** GL thread. Applied to the session on the next [update]; a new GL context brings a new
     * texture, so it's re-applied even to a session that already had one. */
    fun setCameraTextureName(textureId: Int) {
        cameraTextureId = textureId
        textureAppliedTo = null
    }

    /** Called from the GL render thread on every `onDrawFrame`. Returns the updated [Frame] (for
     * the background renderer to re-map its UVs), or null if no session/frame is available yet. */
    fun update(): Frame? {
        val s = session ?: return null
        if (cameraTextureId < 0) {
            // No GL surface yet. ARCore's update() without a texture throws.
            return null
        }
        val frame = try {
            if (textureAppliedTo !== s) {
                s.setCameraTextureName(cameraTextureId)
                textureAppliedTo = s
            }
            if (geometryWidth > 0 && geometryAppliedTo !== s) {
                s.setDisplayGeometry(geometryRotation, geometryWidth, geometryHeight)
                geometryAppliedTo = s
            }
            s.update()
        } catch (e: CameraNotAvailableException) {
            if (!reportedCameraLoss) {
                reportedCameraLoss = true
                statusListener?.onStatus("error", "Camera became unavailable. Go back and try again.")
            }
            return null
        } catch (e: Exception) {
            // SessionPausedException in the instant between a pause and the GL thread stopping, or
            // anything else ARCore throws for one frame: skip it, and the next frame asks again.
            // Logged once per kind, so a persistent one shows up without flooding the log at 30 fps.
            val kind = e.javaClass.simpleName
            if (kind != lastUpdateError) {
                lastUpdateError = kind
                Log.w(TAG, "AR frame update failed", e)
            }
            return null
        }
        lastUpdateError = null

        val camera = frame.camera
        val tracking = camera.trackingState == TrackingState.TRACKING
        if (!tracking && camera.trackingState == TrackingState.PAUSED) {
            val reason = camera.trackingFailureReason
            if (reason != TrackingFailureReason.NONE) {
                Log.d(TAG, "AR tracking paused: $reason")
            }
        }
        val pose = camera.pose
        val translation = pose.translation // [x, y, z]
        val forward = pose.zAxis.let { z -> floatArrayOf(-z[0], -z[1], -z[2]) }
        poseListener?.onPose(tracking, translation[0], translation[2], forward[0], forward[2])

        maybeDetect(frame)
        return frame
    }

    private fun maybeDetect(frame: Frame) {
        if (detectionInFlight) {
            return
        }
        val now = System.currentTimeMillis()
        if (now - lastDetectionAttemptMs < detectionIntervalMs) {
            return
        }
        val image = try {
            frame.acquireCameraImage()
        } catch (e: NotYetAvailableException) {
            return
        } catch (e: Exception) {
            return
        }
        lastDetectionAttemptMs = now
        // Copied out and closed *before* ML Kit sees it. An ARCore camera image lives in the
        // session's own buffers, and ML Kit used to read it on a background thread for as long as
        // detection took — across an Activity pause, when the session stops the camera, or a
        // close, when it frees them. Reading those buffers then, and closing the image into a
        // destroyed session afterwards, is a use-after-free in native code that no catch can
        // stop. The luma plane is all a QR decoder reads, so the copy is ~300 KB at 10 Hz.
        val copy = try {
            Triple(image.width, image.height, lumaAsNv21(image))
        } catch (e: Exception) {
            null
        } finally {
            image.close()
        }
        val (width, height, nv21) = copy ?: return
        val rotation = rotationDegreesForBackCamera()
        val inputImage = try {
            InputImage.fromByteArray(nv21, width, height, rotation, InputImage.IMAGE_FORMAT_NV21)
        } catch (e: Exception) {
            return
        }
        detectionInFlight = true
        barcodeScanner.process(inputImage)
            .addOnSuccessListener { barcodes ->
                val detected = barcodes.mapNotNull { barcode ->
                    val points = barcode.cornerPoints ?: return@mapNotNull null
                    if (points.size != 4) return@mapNotNull null
                    DetectedBarcode(
                        rawValue = barcode.rawValue,
                        corners = points.map { floatArrayOf(it.x.toFloat(), it.y.toFloat()) },
                    )
                }
                // Corner points from ML Kit are in the *rotated* (upright) image's coordinate
                // space, so report the dimensions consistent with that rotation.
                val (reportedWidth, reportedHeight) = if (rotation == 90 || rotation == 270) {
                    height to width
                } else {
                    width to height
                }
                detectionListener?.onDetections(reportedWidth, reportedHeight, detected)
            }
            .addOnCompleteListener {
                detectionInFlight = false
            }
    }

    /** Standard ML Kit rotation-compensation formula for a back-facing camera: the sensor's
     * fixed mounting angle minus how far the device has turned from its natural orientation. */
    private fun rotationDegreesForBackCamera(): Int {
        val deviceDegrees = when (currentDisplayRotation(activity)) {
            Surface.ROTATION_0 -> 0
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        return (sensorOrientation - deviceDegrees + 360) % 360
    }

    companion object {
        private const val TAG = "ArSessionManager"

        private fun backCameraSensorOrientation(activity: Activity): Int = try {
            val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            manager.cameraIdList.asSequence()
                .map { manager.getCameraCharacteristics(it) }
                .filter {
                    it.get(CameraCharacteristics.LENS_FACING) ==
                        CameraCharacteristics.LENS_FACING_BACK
                }
                .mapNotNull { it.get(CameraCharacteristics.SENSOR_ORIENTATION) }
                .firstOrNull() ?: 90
        } catch (e: Exception) {
            90 // typical back-camera mounting angle; a wrong value just skews QR corners,
               // never crashes — ML Kit still attempts detection.
        }

        /** An NV21 frame carrying [image]'s luma and neutral chroma, so the image can be closed
         * at once. A QR decoder reads luminance only. */
        private fun lumaAsNv21(image: Image): ByteArray {
            val width = image.width
            val height = image.height
            val plane = image.planes[0]
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride
            val luma = plane.buffer
            val lumaSize = width * height
            val out = ByteArray(lumaSize + 2 * ((width + 1) / 2) * ((height + 1) / 2))
            if (pixelStride == 1) {
                for (row in 0 until height) {
                    luma.position(row * rowStride)
                    luma.get(out, row * width, width)
                }
            } else {
                for (row in 0 until height) {
                    val base = row * rowStride
                    for (col in 0 until width) {
                        out[row * width + col] = luma.get(base + col * pixelStride)
                    }
                }
            }
            java.util.Arrays.fill(out, lumaSize, out.size, 128.toByte())
            return out
        }
    }
}

/** The display's rotation, asked in a way every supported API level has: `Activity.getDisplay()`
 * only exists from API 30, and this app's floor is 28. */
@Suppress("DEPRECATION")
internal fun currentDisplayRotation(activity: Activity): Int =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        activity.display?.rotation ?: Surface.ROTATION_0
    } else {
        activity.windowManager.defaultDisplay.rotation
    }

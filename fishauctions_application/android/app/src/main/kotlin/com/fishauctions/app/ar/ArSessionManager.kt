package com.fishauctions.app.ar

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
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

    private var session: Session? = null
    private var installRequested = false
    private val barcodeScanner = BarcodeScanning.getClient(
        BarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .build(),
    )
    @Volatile private var detectionInFlight = false
    private var lastDetectionAttemptMs = 0L
    private val detectionIntervalMs = 100L // ~10 Hz — plenty for a hand-held scan sweep

    /** Creates and configures the session if needed. Returns true when a session is ready to
     * [resume]. False (with [statusListener] told why) means AR mode can't proceed on this
     * device/build — the Dart side shows an explainer instead of the camera view. */
    fun ensureSession(): Boolean {
        if (session != null) {
            return true
        }
        statusListener?.onStatus("checking", null)
        try {
            val availability = ArCoreApk.getInstance().checkAvailability(activity)
            if (availability.isTransient) {
                // Rare (network check in flight) — the view retries ensureSession() on its next
                // lifecycle callback rather than blocking here.
                statusListener?.onStatus("checking", null)
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

    fun resume() {
        val s = session ?: return
        try {
            s.resume()
        } catch (e: CameraNotAvailableException) {
            statusListener?.onStatus("error", "Camera is in use by another app.")
            session = null
        }
    }

    fun pause() {
        session?.pause()
    }

    fun close() {
        session?.close()
        session = null
        barcodeScanner.close()
    }

    fun setDisplayGeometry(rotation: Int, width: Int, height: Int) {
        session?.setDisplayGeometry(rotation, width, height)
    }

    fun setCameraTextureName(textureId: Int) {
        session?.setCameraTextureName(textureId)
    }

    /** Called from the GL render thread on every `onDrawFrame`. Returns the updated [Frame] (for
     * the background renderer to re-map its UVs), or null if no session/frame is available yet. */
    fun update(): Frame? {
        val s = session ?: return null
        val frame = try {
            s.update()
        } catch (e: CameraNotAvailableException) {
            statusListener?.onStatus("error", "Camera became unavailable.")
            return null
        }

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
        detectionInFlight = true
        val rotation = rotationDegreesForBackCamera(activity)
        val inputImage = try {
            InputImage.fromMediaImage(image, rotation)
        } catch (e: Exception) {
            image.close()
            detectionInFlight = false
            return
        }
        val width = image.width
        val height = image.height
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
                image.close()
                detectionInFlight = false
            }
    }

    companion object {
        private const val TAG = "ArSessionManager"

        /** Standard ML Kit rotation-compensation formula for a back-facing camera: the sensor's
         * fixed mounting angle minus how far the device has turned from its natural orientation. */
        private fun rotationDegreesForBackCamera(activity: Activity): Int {
            val sensorOrientation = try {
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
            val deviceDegrees = when (activity.display?.rotation ?: Surface.ROTATION_0) {
                Surface.ROTATION_0 -> 0
                Surface.ROTATION_90 -> 90
                Surface.ROTATION_180 -> 180
                Surface.ROTATION_270 -> 270
                else -> 0
            }
            return (sensorOrientation - deviceDegrees + 360) % 360
        }
    }
}

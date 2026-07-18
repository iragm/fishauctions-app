package com.fishauctions.app

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import com.squareup.sdk.mobilepayments.MobilePaymentsSdk
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.atan

class MainActivity : FlutterActivity() {
    private val channelName = "com.fishauctions.app/platform"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                    "isTapToPayCapable" -> result.success(isTapToPayCapable())
                    "getCameraFov" -> result.success(backCameraHorizontalFovDeg())
                    "initializeSquare" -> initializeSquare(call.argument("applicationId"), result)
                    else -> result.notImplemented()
                }
            }
    }

    // Horizontal field of view of the back main camera in degrees, or null when
    // it can't be determined. Derived from the lens focal length and the
    // physical sensor width (hfov = 2·atan(sensorWidth / 2f)) — the same wide
    // camera CameraX (mobile_scanner) selects by default. AR lot mode uses it
    // to compute accurate QR bearings without a hardcoded FOV guess.
    private fun backCameraHorizontalFovDeg(): Double? = try {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        manager.cameraIdList.asSequence()
            .map { manager.getCameraCharacteristics(it) }
            .filter { it.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK }
            .mapNotNull { chars ->
                val focal = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                    ?.firstOrNull() ?: return@mapNotNull null
                val sensor = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                    ?: return@mapNotNull null
                Math.toDegrees(2.0 * atan(sensor.width / (2.0 * focal)))
            }
            .firstOrNull()
    } catch (e: Throwable) {
        null
    }

    // Whether this device can take a Square Tap to Pay charge: NFC hardware plus
    // Android 12 (API 31+). The Square Flutter plugin's own isDeviceCapable() is
    // iOS-only (it routes to notImplemented() on Android and throws), so the
    // Android capability gate has to be answered here from the platform.
    private fun isTapToPayCapable(): Boolean {
        val hasNfc = packageManager.hasSystemFeature(PackageManager.FEATURE_NFC)
        return hasNfc && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
    }

    // Initializes the Square Mobile Payments SDK with the deployment's Square
    // Application ID, which the backend returns per invoice (so nothing
    // Square-specific is baked into the app). The SDK must be initialized once
    // per process before any authorize()/startPayment() call — the Flutter
    // plugin doesn't expose initialize(), hence this channel.
    //
    // Square has no re-initialize, so we init once and remember the id: the same
    // id is a no-op, and a *different* id (a deployment pointing at another
    // Square account) is refused with a clear "restart to switch" error rather
    // than risking a charge on the wrong account.
    private fun initializeSquare(applicationId: String?, result: MethodChannel.Result) {
        if (applicationId.isNullOrBlank()) {
            result.error("missing_app_id", "applicationId is required", null)
            return
        }
        val current = squareInitializedAppId
        when {
            current == applicationId -> result.success(null)
            current != null -> result.error(
                "already_initialized_other",
                "Square SDK already initialized for a different application id; " +
                    "restart the app to switch deployments.",
                null,
            )
            else -> try {
                MobilePaymentsSdk.initialize(applicationId, application)
                squareInitializedAppId = applicationId
                result.success(null)
            } catch (e: Throwable) {
                result.error("init_failed", e.message ?: e.toString(), null)
            }
        }
    }

    companion object {
        // Process-wide: survives Activity recreation, matching the SDK's
        // process-scoped singleton.
        @Volatile
        private var squareInitializedAppId: String? = null
    }
}

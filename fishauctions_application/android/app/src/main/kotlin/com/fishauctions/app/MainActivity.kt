package com.fishauctions.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.nfc.NfcAdapter
import android.os.Build
import android.provider.Settings
import android.speech.SpeechRecognizer
import com.fishauctions.app.ar.ArCameraViewFactory
import com.fishauctions.app.ar.ArEventBridge
import com.fishauctions.app.speech.BiasedSpeechBridge
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.squareup.sdk.mobilepayments.MobilePaymentsSdk
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import kotlin.math.atan

class MainActivity : FlutterActivity() {
    private val channelName = "com.fishauctions.app/platform"
    private var arCameraViewFactory: ArCameraViewFactory? = null

    // Held for the engine's lifetime: it owns the speech channels' handlers.
    private var biasedSpeechBridge: BiasedSpeechBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                    // Native crashes and ANRs since the last call; Dart sends them on.
                    "takePendingCrashes" -> result.success(CrashCapture.take(applicationContext))
                    "isTapToPayCapable" -> result.success(isTapToPayCapable())
                    "isNfcEnabled" -> result.success(isNfcEnabled())
                    "isDeveloperModeEnabled" -> result.success(isDeveloperModeEnabled())
                    "openNfcSettings" -> openNfcSettings(result)
                    "speechRecognitionAvailable" -> result.success(isSpeechRecognitionAvailable())
                    "getCameraFov" -> result.success(backCameraHorizontalFovDeg())
                    "getLensDistortion" -> result.success(backCameraLensDistortion())
                    "detectBarcodes" -> detectBarcodes(
                        call.argument<ByteArray>("bytes"),
                        call.argument<List<String>>("formats").orEmpty(),
                        result,
                    )
                    "initializeSquare" -> initializeSquare(call.argument("applicationId"), result)
                    else -> result.notImplemented()
                }
            }

        // AR lot mode's camera view (ar/ArCameraPlatformView.kt): ARCore owns the camera for
        // visual-inertial pose tracking + feeds ML Kit for QR detection, replacing the
        // mobile_scanner/CameraX pipeline that screen used to use. Two EventChannels stream pose
        // (+ session status) and detections out; the platform view itself is registered under
        // "com.fishauctions.app/ar_camera" for the Dart-side AndroidView.
        //
        // The channels' stream handlers are attached here, at engine setup, rather than when the
        // platform view is created: Dart subscribes before it mounts the view, so registering
        // them any later loses the subscription outright (see ar/ArEventBridge.kt).
        val poseEvents = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.fishauctions.app/ar_pose")
        val detectionEvents =
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.fishauctions.app/ar_detections")
        val factory = ArCameraViewFactory(this, ArEventBridge(this, poseEvents, detectionEvents))
        arCameraViewFactory = factory
        flutterEngine.platformViewsController.registry
            .registerViewFactory("com.fishauctions.app/ar_camera", factory)

        // Voice set-winners' `biased` backend (speech/BiasedSpeechBridge.kt): SpeechRecognizer
        // driven directly so the auction's own lot and bidder numbers can be passed as
        // EXTRA_BIASING_STRINGS. speech_to_text never sets that extra and has no way to, which is
        // the only reason we own a recognizer at all — everything above one utterance stays in
        // Dart (RestartingSpeechBackend).
        //
        // Registered here, at engine setup, for the same reason the AR channels are: Dart
        // subscribes to the event stream from `ensureRecognizer()` before the first `start`, and a
        // channel with no stream handler isn't registered with the messenger at all.
        biasedSpeechBridge = BiasedSpeechBridge(
            this,
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.fishauctions.app/speech"),
            EventChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "com.fishauctions.app/speech_events",
            ),
        )
    }

    // PlatformViews don't receive Activity lifecycle callbacks automatically — ARCore's Session
    // must be resumed/paused in step with the Activity (per Google's own samples) or a background
    // AR screen keeps the camera open, or a foregrounded one never restarts it.
    override fun onResume() {
        super.onResume()
        arCameraViewFactory?.activeView?.onHostResume()
    }

    override fun onPause() {
        arCameraViewFactory?.activeView?.onHostPause()
        super.onPause()
    }

    // Backs the WebView's BarcodeDetector (lib/utils/native_barcode_detector.dart) on a WebView
    // that ships none of its own — Chromium's, where present, is kept and never reaches here.
    // Decodes one JPEG of a camera frame the page snapshotted and answers in the Shape Detection
    // API's format names, with corners normalized to 0..1 so the page can scale them back onto
    // whatever it captured. One scanner per format set, reused: building one per frame costs more
    // than the detection.
    private val barcodeScanners = HashMap<Int, BarcodeScanner>()
    private val barcodeDecoder = Executors.newSingleThreadExecutor()

    private fun detectBarcodes(bytes: ByteArray?, formats: List<String>, result: MethodChannel.Result) {
        if (bytes == null || bytes.isEmpty()) {
            result.success(emptyList<Any>())
            return
        }
        val mask = formats.mapNotNull { barcodeFormats[it] }.fold(0) { acc, f -> acc or f }
            .takeIf { it != 0 } ?: Barcode.FORMAT_ALL_FORMATS
        barcodeDecoder.execute {
            // Decoding the JPEG is the one slow step that isn't ML Kit's own, so it stays off the
            // UI thread; the scanner then runs on ML Kit's executor and answers on the main one.
            val bitmap = try {
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            } catch (e: Throwable) {
                null
            }
            runOnUiThread {
                if (bitmap == null || isFinishing || isDestroyed) {
                    bitmap?.recycle()
                    result.success(emptyList<Any>())
                    return@runOnUiThread
                }
                val scanner = barcodeScanners.getOrPut(mask) {
                    BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(mask).build())
                }
                val width = bitmap.width.toDouble()
                val height = bitmap.height.toDouble()
                try {
                    scanner.process(InputImage.fromBitmap(bitmap, 0))
                        .addOnSuccessListener { barcodes ->
                            result.success(
                                barcodes.mapNotNull { barcode ->
                                    val value = barcode.rawValue
                                    val points = barcode.cornerPoints
                                    if (value.isNullOrEmpty() || points == null) return@mapNotNull null
                                    mapOf(
                                        "rawValue" to value,
                                        "format" to (barcodeFormatNames[barcode.format] ?: "unknown"),
                                        "corners" to points.map { listOf(it.x / width, it.y / height) },
                                    )
                                },
                            )
                        }
                        .addOnFailureListener { e ->
                            result.error("detect_failed", e.message ?: e.toString(), null)
                        }
                        .addOnCompleteListener { bitmap.recycle() }
                } catch (e: Throwable) {
                    bitmap.recycle()
                    result.error("detect_failed", e.message ?: e.toString(), null)
                }
            }
        }
    }

    override fun onDestroy() {
        barcodeScanners.values.forEach { it.close() }
        barcodeScanners.clear()
        barcodeDecoder.shutdown()
        super.onDestroy()
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

    // The back main camera's Brown-Conrady radial+tangential distortion coefficients
    // [k0, k1, k2, k3, k4] (CameraCharacteristics.LENS_DISTORTION, API 28+ — same floor as
    // the app's minSdk), or null when the characteristic isn't reported (older/unsupported
    // camera HAL) or doesn't have exactly 5 elements. These operate on the same pinhole-normalized
    // coordinates (pixel offset from the optical center, divided by focal length in pixels) that
    // ar_geometry.dart's bearing/depression math already uses, so — unlike LENS_INTRINSIC_CALIBRATION's
    // pixel-space principal point — no separate coordinate-system reconciliation with mobile_scanner's
    // analysis-image resolution is needed: the app assumes a centered optical center, which is standard
    // for a rear main camera and consistent with the existing (distortion-free) bearing model.
    private fun backCameraLensDistortion(): List<Float>? = try {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        manager.cameraIdList.asSequence()
            .map { manager.getCameraCharacteristics(it) }
            .filter { it.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK }
            .mapNotNull { chars ->
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return@mapNotNull null
                chars.get(CameraCharacteristics.LENS_DISTORTION)?.toList()?.takeIf { it.size == 5 }
            }
            .firstOrNull()
    } catch (e: Throwable) {
        null
    }

    // Whether this phone has a speech recognition service — without requesting RECORD_AUDIO and
    // without constructing a recognizer.
    //
    // This exists because speech_to_text has no permission-free capability check: its initialize()
    // *requests* the microphone and then returns whether the permission is held, which is a
    // different question. Answering the page's voiceGetState() with it popped a permission dialog
    // on page load and reported "no voice on this phone" for every phone that hadn't already
    // granted it (see PlatformSpeechBackend.isCapable).
    //
    // Package visibility (Android 11+) matters here: isRecognitionAvailable() only sees a
    // recognition service because AndroidManifest.xml declares the matching <queries><intent> for
    // android.speech.RecognitionService. Without it this returns false on every modern phone.
    //
    // The on-device check is a separate question from the network one — a phone with Google's
    // offline speech pack but no network recognizer still works, and voice deliberately prefers
    // on-device (an auction hall's wifi is bad).
    private fun isSpeechRecognitionAvailable(): Boolean = try {
        val onDevice = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
        SpeechRecognizer.isRecognitionAvailable(this) || onDevice
    } catch (e: Throwable) {
        // Optimistic: a hidden microphone button on hardware that works is the worse failure, and
        // the real attempt reports precisely when the user taps Listen.
        true
    }

    // Whether this device can take a Square Tap to Pay charge: NFC hardware plus
    // Android 12 (API 31+). The Square Flutter plugin's own isDeviceCapable() is
    // iOS-only (it routes to notImplemented() on Android and throws), so the
    // Android capability gate has to be answered here from the platform.
    private fun isTapToPayCapable(): Boolean {
        val hasNfc = packageManager.hasSystemFeature(PackageManager.FEATURE_NFC)
        return hasNfc && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
    }

    // Whether NFC is actually turned ON right now — distinct from isTapToPayCapable(), which only
    // checks the device *has* an NFC radio. A device can be capable (hardware + API 31+) with NFC
    // toggled off in system settings, which the Square SDK surfaces as an opaque "connect hardware to
    // take card payments" prompt with no card-tap option and no catchable PaymentError — from Square's
    // side there's simply no reader available. Checking this separately lets the app show a specific
    // "turn on NFC" message with a settings deep link instead of the generic device-incapable one.
    private fun isNfcEnabled(): Boolean {
        val adapter = NfcAdapter.getDefaultAdapter(this) ?: return false
        return adapter.isEnabled
    }

    // Whether Android's Developer options are switched on. Square's Tap to Pay refuses to take a
    // card on a device with developer mode enabled (a device-integrity requirement of the
    // contactless kernel — the same class of check as its root detection), and it surfaces that
    // the same opaque way as every other reader prerequisite: no tap option, no catchable error.
    // The app can't fix it, so this only drives a small non-blocking warning in the payment sheet
    // rather than a gate.
    private fun isDeveloperModeEnabled(): Boolean = try {
        Settings.Global.getInt(contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) != 0
    } catch (e: Throwable) {
        false
    }

    // Opens the system NFC toggle screen so the cashier can turn it on without hunting through
    // Settings. No result payload needed — the app re-checks isNfcEnabled() on the next retry.
    private fun openNfcSettings(result: MethodChannel.Result) {
        try {
            startActivity(Intent(Settings.ACTION_NFC_SETTINGS))
            result.success(null)
        } catch (e: Throwable) {
            result.error("open_nfc_settings_failed", e.message ?: e.toString(), null)
        }
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
        val current = FishAuctionsApplication.squareInitializedAppId
        when {
            current == applicationId -> {
                FishAuctionsApplication.cacheSquareApplicationId(this, applicationId)
                result.success(null)
            }
            current != null -> {
                // Initialized early from a cached id the deployment has since changed. The SDK
                // can't re-initialize, but the cache must follow the server or the restart this
                // asks for would initialize from the stale id again.
                FishAuctionsApplication.cacheSquareApplicationId(this, applicationId)
                result.error(
                    "already_initialized_other",
                    "Square SDK already initialized for a different application id; " +
                        "restart the app to switch deployments.",
                    null,
                )
            }
            else -> try {
                MobilePaymentsSdk.initialize(applicationId, application)
                FishAuctionsApplication.squareInitializedAppId = applicationId
                // So the next process initializes in Application.onCreate, before any Square
                // Activity Android might restore (FishAuctionsApplication).
                FishAuctionsApplication.cacheSquareApplicationId(this, applicationId)
                result.success(null)
            } catch (e: Throwable) {
                result.error("init_failed", e.message ?: e.toString(), null)
            }
        }
    }

    companion object {
        // Shape Detection API format names ↔ ML Kit's. UPC-A and EAN-13 stay distinct here, as
        // ML Kit reports them.
        private val barcodeFormats = mapOf(
            "aztec" to Barcode.FORMAT_AZTEC,
            "codabar" to Barcode.FORMAT_CODABAR,
            "code_128" to Barcode.FORMAT_CODE_128,
            "code_39" to Barcode.FORMAT_CODE_39,
            "code_93" to Barcode.FORMAT_CODE_93,
            "data_matrix" to Barcode.FORMAT_DATA_MATRIX,
            "ean_13" to Barcode.FORMAT_EAN_13,
            "ean_8" to Barcode.FORMAT_EAN_8,
            "itf" to Barcode.FORMAT_ITF,
            "pdf417" to Barcode.FORMAT_PDF417,
            "qr_code" to Barcode.FORMAT_QR_CODE,
            "upc_a" to Barcode.FORMAT_UPC_A,
            "upc_e" to Barcode.FORMAT_UPC_E,
        )
        private val barcodeFormatNames = barcodeFormats.entries.associate { (name, format) -> format to name }
    }
}

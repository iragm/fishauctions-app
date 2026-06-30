package com.fishauctions.app

import android.os.Build
import com.squareup.sdk.mobilepayments.MobilePaymentsSdk
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.fishauctions.app/platform"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                    "initializeSquare" -> initializeSquare(call.argument("applicationId"), result)
                    else -> result.notImplemented()
                }
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

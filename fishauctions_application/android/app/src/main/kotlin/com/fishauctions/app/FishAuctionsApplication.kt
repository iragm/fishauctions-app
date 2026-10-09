package com.fishauctions.app

import android.app.Application
import android.content.Context
import android.util.Log
import com.squareup.sdk.mobilepayments.MobilePaymentsSdk

/**
 * Initializes the Square SDK at process start from the application id the last successful
 * `initializeSquare` call cached — the same early init iOS does in `didFinishLaunching`.
 *
 * Square's Android setup asks for `MobilePaymentsSdk.initialize()` in `Application.onCreate`, and
 * this is why: when Android reclaims the process while Square's own payment Activity is on top
 * (the cashier switched apps mid-charge), it recreates *that* Activity in a fresh process.
 * MainActivity never runs, nothing initializes the SDK, and Square's Activity touches it anyway —
 * the uninitialized-SDK crash `PlatformBridge.squareInitialized` guards against on the Dart side,
 * reached from a place no Dart guard can see.
 *
 * The id is server-driven (one binary serves any deployment), so the very first run still
 * initializes late, over the channel; every later launch starts initialized.
 */
class FishAuctionsApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // First, so a crash anywhere later in this process still reaches the next launch.
        CrashCapture.install(this)
        val cached = cachedSquareApplicationId(this) ?: return
        try {
            MobilePaymentsSdk.initialize(cached, this)
            squareInitializedAppId = cached
        } catch (e: Throwable) {
            // A bad cached id must not take the launch with it; the channel call retries with the
            // server's id once config loads.
            Log.w(TAG, "Square early init failed", e)
        }
    }

    companion object {
        private const val TAG = "FishAuctionsApplication"
        private const val PREFS = "fishauctions_square"
        private const val KEY_APP_ID = "square_application_id"

        /** The id the SDK was initialized with in this process, or null. Process-wide, matching
         * the SDK's process-scoped singleton; read by MainActivity's `initializeSquare`. */
        @Volatile
        var squareInitializedAppId: String? = null

        fun cachedSquareApplicationId(context: Context): String? =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_APP_ID, null)
                ?.takeIf { it.isNotBlank() }

        fun cacheSquareApplicationId(context: Context, applicationId: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_APP_ID, applicationId)
                .apply()
        }
    }
}

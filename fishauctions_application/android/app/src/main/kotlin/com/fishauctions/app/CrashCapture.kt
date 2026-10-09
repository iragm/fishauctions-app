package com.fishauctions.app

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import org.json.JSONObject
import java.io.File
import java.time.Instant

/**
 * Native crashes and ANRs, held until Dart sends them to the backend (`CrashReporter`).
 *
 * A Dart error is caught in Dart, but an exception on a JVM thread (the AR GL thread, a plugin's
 * callback) or a crash in native code ends the process before anything of ours can run. Two
 * sources cover that:
 *
 * - **JVM exceptions**: a default uncaught-exception handler writes the stack to a file, then hands
 *   the crash on to the previous handler unchanged, so the process still dies the way it did.
 * - **Native crashes and ANRs**: Android's own record of why the process last ended
 *   (`ApplicationExitInfo`, API 30+), read on the next launch. A native crash's tombstone is a
 *   binary protobuf, so only its description and signal come through; an ANR keeps its main thread.
 *
 * `take` gives them to Dart over the platform channel and deletes them.
 */
object CrashCapture {
    private const val TAG = "CrashCapture"
    private const val DIR = "pending_crashes"
    private const val PREFS = "fishauctions_crashes"
    private const val KEY_LAST_EXIT = "last_exit_timestamp"

    /** More than this many waiting is a crash loop; the newest say the same as the rest. */
    private const val MAX_PENDING = 10
    private const val MAX_ANR_LINES = 60

    fun install(context: Context) {
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                save(
                    app,
                    JSONObject()
                        .put("kind", "native")
                        .put("platform", "android")
                        .put("fatal", true)
                        .put("message", "${error.javaClass.name}: ${error.message ?: ""}")
                        .put("stack", "Thread ${thread.name}\n" + Log.getStackTraceString(error))
                        .put("app_version", appVersion(app))
                        .put("occurred_at", Instant.now().toString()),
                )
            } catch (_: Throwable) {
                // Nothing here may stop the crash reaching the system's handler.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    /** `{device, os_version, crashes: [...]}`; the crashes are deleted once read. */
    fun take(context: Context): Map<String, Any> {
        val crashes = mutableListOf<Map<String, Any?>>()
        val dir = File(context.filesDir, DIR)
        dir.listFiles()?.sortedBy { it.name }?.forEach { file ->
            try {
                crashes.add(toMap(JSONObject(file.readText())))
            } catch (e: Exception) {
                Log.w(TAG, "Unreadable crash file ${file.name}", e)
            }
            file.delete()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                crashes.addAll(exitReasons(context))
            } catch (e: Exception) {
                Log.w(TAG, "Could not read exit reasons", e)
            }
        }
        return mapOf(
            "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "os_version" to "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            "crashes" to crashes,
        )
    }

    private fun save(context: Context, crash: JSONObject) {
        val dir = File(context.filesDir, DIR)
        dir.mkdirs()
        if ((dir.list()?.size ?: 0) >= MAX_PENDING) return
        File(dir, "${System.currentTimeMillis()}.json").writeText(crash.toString())
    }

    /**
     * Native crashes and ANRs since the last call. JVM crashes (`REASON_CRASH`) are left out: the
     * handler above already has them, with the stack this can't give.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun exitReasons(context: Context): List<Map<String, Any?>> {
        val manager = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val since = prefs.getLong(KEY_LAST_EXIT, -1L)
        val exits = manager.getHistoricalProcessExitReasons(null, 0, 10)
        val newest = exits.maxOfOrNull { it.timestamp } ?: return emptyList()
        prefs.edit().putLong(KEY_LAST_EXIT, maxOf(newest, since)).apply()
        // The first launch of a build with this code has no marker; history from before it was
        // never ours to report.
        if (since < 0) return emptyList()
        return exits
            .filter { it.timestamp > since }
            .filter {
                it.reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
                    it.reason == ApplicationExitInfo.REASON_ANR
            }
            .map { exit ->
                val anr = exit.reason == ApplicationExitInfo.REASON_ANR
                mapOf(
                    "kind" to if (anr) "anr" else "native",
                    "platform" to "android",
                    "fatal" to true,
                    "message" to if (anr) {
                        "ANR: ${exit.description ?: ""}"
                    } else {
                        "NativeCrash: signal ${exit.status} ${exit.description ?: ""}"
                    },
                    "stack" to if (anr) mainThread(exit) else "",
                    "app_version" to appVersion(context),
                    "occurred_at" to Instant.ofEpochMilli(exit.timestamp).toString(),
                )
            }
    }

    /** The `"main"` thread's block of an ANR's trace dump: the one that was stuck. */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun mainThread(exit: ApplicationExitInfo): String {
        // A dump of every thread runs to megabytes; read only as far as the main thread's block.
        return exit.traceInputStream?.bufferedReader()?.use { reader ->
            reader.lineSequence()
                .dropWhile { !it.startsWith("\"main\"") }
                .takeWhile { it.isNotBlank() }
                .take(MAX_ANR_LINES)
                .joinToString("\n")
        } ?: ""
    }

    /** "1.0.0+12" like Dart's. */
    private fun appVersion(context: Context): String = try {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        "${info.versionName}+${info.longVersionCode}"
    } catch (_: Exception) {
        ""
    }

    private fun toMap(json: JSONObject): Map<String, Any?> =
        json.keys().asSequence().associateWith { key -> json.opt(key) }
}

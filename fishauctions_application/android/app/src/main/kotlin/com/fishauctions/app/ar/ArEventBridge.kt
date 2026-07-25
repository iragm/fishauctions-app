package com.fishauctions.app.ar

import android.app.Activity
import io.flutter.plugin.common.EventChannel

/**
 * Owns the two AR EventChannels (`ar_pose`, `ar_detections`) for the whole engine's lifetime and
 * relays [ArCameraPlatformView]'s events into them.
 *
 * This deliberately does *not* live on the platform view, which is what it used to do and why AR
 * mode was dead:
 *
 *  1. Dart subscribes to both channels in `ArLotsScreen._initCamera()` and only *then* mounts
 *     `ArCameraView`, so the `listen` message reached the platform before the view existed —
 *     i.e. before anything had called `setStreamHandler`. An EventChannel with no stream handler
 *     isn't registered with the messenger at all, so the message hit the no-handler default,
 *     came back as a `MissingPluginException`, and Dart's `EventChannel` reported it to
 *     `FlutterError` and never retried: both streams were dead for the life of the screen. No
 *     pose/status ⇒ `_arStatus` stuck at `checking` ⇒ the permanent spinner; no detections ⇒
 *     nothing ever scanned. Registering here, at engine setup, means a handler is always in
 *     place before Dart can possibly listen.
 *
 *  2. Session status is a one-shot event, and `ensureSession()` runs in the view's constructor —
 *     ahead of Dart's `onListen` in the other ordering. So [emitStatus] is sticky: the last
 *     status is replayed to a newly-attached sink, and a view teardown clears it
 *     ([clearStatus]) so a stale `ready` can't outlive its session.
 */
class ArEventBridge(
    private val activity: Activity,
    poseEvents: EventChannel,
    detectionEvents: EventChannel,
) {
    // Touched only on the Android UI thread: `onListen`/`onCancel` arrive there, and every
    // emit* hops there (the GL render thread is what calls them).
    private var poseSink: EventChannel.EventSink? = null
    private var detectionSink: EventChannel.EventSink? = null
    private var lastStatus: String? = null
    private var lastStatusMessage: String? = null

    init {
        poseEvents.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    poseSink = sink
                    lastStatus?.let { sink.success(statusPayload(it, lastStatusMessage)) }
                }

                override fun onCancel(args: Any?) {
                    poseSink = null
                }
            },
        )
        detectionEvents.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    detectionSink = sink
                }

                override fun onCancel(args: Any?) {
                    detectionSink = null
                }
            },
        )
    }

    fun emitStatus(status: String, message: String?) {
        activity.runOnUiThread {
            lastStatus = status
            lastStatusMessage = message
            poseSink?.success(statusPayload(status, message))
        }
    }

    fun emitPose(tracking: Boolean, px: Float, pz: Float, fx: Float, fz: Float) {
        activity.runOnUiThread {
            val payload = HashMap<String, Any?>()
            payload["type"] = "pose"
            payload["tracking"] = tracking
            payload["px"] = px.toDouble()
            payload["pz"] = pz.toDouble()
            payload["fx"] = fx.toDouble()
            payload["fz"] = fz.toDouble()
            poseSink?.success(payload)
        }
    }

    fun emitDetections(
        imageWidth: Int,
        imageHeight: Int,
        barcodes: List<ArSessionManager.DetectedBarcode>,
    ) {
        activity.runOnUiThread {
            val payload = HashMap<String, Any?>()
            payload["imageWidth"] = imageWidth
            payload["imageHeight"] = imageHeight
            payload["barcodes"] = barcodes.map { b ->
                hashMapOf(
                    "rawValue" to b.rawValue,
                    "corners" to b.corners.map { listOf(it[0].toDouble(), it[1].toDouble()) },
                )
            }
            detectionSink?.success(payload)
        }
    }

    /** Forgets the sticky status — called when the AR view is disposed, so the next screen's
     * subscriber doesn't get replayed a `ready` belonging to a session that no longer exists. */
    fun clearStatus() {
        activity.runOnUiThread {
            lastStatus = null
            lastStatusMessage = null
        }
    }

    private fun statusPayload(status: String, message: String?): HashMap<String, Any?> {
        val payload = HashMap<String, Any?>()
        payload["type"] = "status"
        payload["status"] = status
        payload["message"] = message
        return payload
    }
}

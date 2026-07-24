package com.fishauctions.app.ar

import android.app.Activity
import android.content.Context
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Creates [ArCameraPlatformView]s for the `com.fishauctions.app/ar_camera` platform view
 * (registered in MainActivity). Keeps the single live instance so MainActivity can forward
 * Activity lifecycle callbacks to it — PlatformViews don't receive those automatically.
 */
class ArCameraViewFactory(
    private val activity: Activity,
    private val poseEvents: EventChannel,
    private val detectionEvents: EventChannel,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    var activeView: ArCameraPlatformView? = null
        private set

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val view = ArCameraPlatformView(context, activity, poseEvents, detectionEvents) {
            activeView = null
        }
        activeView = view
        return view
    }
}

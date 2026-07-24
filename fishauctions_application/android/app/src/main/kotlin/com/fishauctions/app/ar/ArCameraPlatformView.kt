package com.fishauctions.app.ar

import android.app.Activity
import android.content.Context
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.view.View
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.platform.PlatformView
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * The Flutter-embedded AR camera view: a [GLSurfaceView] rendering ARCore's camera passthrough
 * (via [BackgroundRenderer]), driven by one [ArSessionManager]. Composed into the Flutter widget
 * tree as a normal Android View (Hybrid Composition — the same mechanism flutter_inappwebview
 * already uses in this app), not through Flutter's Texture registry: ARCore's
 * `setCameraTextureName` needs a GL texture living in a context *this view's own render thread*
 * controls, so there's no Flutter-texture bridging to build — just a standard ARCore sample
 * `GLSurfaceView` wrapped as a [PlatformView].
 *
 * Pose and QR-detection events are pushed out over the two EventChannels registered in
 * MainActivity (shared globally — only one AR screen is ever shown at a time, so there is
 * exactly one live view per process).
 */
class ArCameraPlatformView(
    context: Context,
    private val activity: Activity,
    poseEvents: EventChannel,
    detectionEvents: EventChannel,
    private val onDispose: () -> Unit,
) : PlatformView {
    private val glView: GLSurfaceView = GLSurfaceView(context)
    private val sessionManager = ArSessionManager(activity)
    private val backgroundRenderer = BackgroundRenderer()

    private var poseSink: EventChannel.EventSink? = null
    private var detectionSink: EventChannel.EventSink? = null

    init {
        poseEvents.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    poseSink = sink
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

        sessionManager.statusListener = object : ArSessionManager.StatusListener {
            override fun onStatus(status: String, message: String?) {
                activity.runOnUiThread {
                    val payload = HashMap<String, Any?>()
                    payload["type"] = "status"
                    payload["status"] = status
                    payload["message"] = message
                    poseSink?.success(payload)
                }
            }
        }
        sessionManager.poseListener = object : ArSessionManager.PoseListener {
            override fun onPose(tracking: Boolean, px: Float, pz: Float, fx: Float, fz: Float) {
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
        }
        sessionManager.detectionListener = object : ArSessionManager.DetectionListener {
            override fun onDetections(
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
        }

        glView.setEGLContextClientVersion(2)
        glView.preserveEGLContextOnPause = true
        glView.setRenderer(
            object : GLSurfaceView.Renderer {
                override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
                    GLES20.glClearColor(0f, 0f, 0f, 1f)
                    backgroundRenderer.createOnGlThread()
                    sessionManager.setCameraTextureName(backgroundRenderer.textureId)
                }

                override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
                    GLES20.glViewport(0, 0, width, height)
                    val rotation = activity.display?.rotation ?: 0
                    sessionManager.setDisplayGeometry(rotation, width, height)
                }

                override fun onDrawFrame(gl: GL10?) {
                    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
                    val frame = sessionManager.update() ?: return
                    backgroundRenderer.updateTexCoords(frame)
                    backgroundRenderer.draw()
                }
            },
        )
        glView.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY

        // The view mounts only once camera permission is already granted (Dart requests it
        // before pushing the AR route), so it's safe to try starting the session immediately.
        if (sessionManager.ensureSession()) {
            sessionManager.resume()
        }
        glView.onResume()
    }

    /** Called from MainActivity's own onResume/onPause — PlatformViews don't get Activity
     * lifecycle callbacks automatically. Re-attempts session creation on resume in case it
     * couldn't start earlier (e.g. the ARCore installer flow returned control to the app). */
    fun onHostResume() {
        if (sessionManager.ensureSession()) {
            sessionManager.resume()
        }
        glView.onResume()
    }

    fun onHostPause() {
        glView.onPause()
        sessionManager.pause()
    }

    override fun getView(): View = glView

    override fun dispose() {
        glView.onPause()
        sessionManager.close()
        poseSink = null
        detectionSink = null
        onDispose()
    }
}

package com.fishauctions.app.ar

import android.app.Activity
import android.content.Context
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.view.View
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
 * Pose and QR-detection events are pushed out through [ArEventBridge], which owns the two
 * EventChannels for the engine's lifetime — deliberately not this view, see the note there.
 */
class ArCameraPlatformView(
    context: Context,
    private val activity: Activity,
    private val events: ArEventBridge,
    private val onDispose: () -> Unit,
) : PlatformView {
    private val glView: GLSurfaceView = GLSurfaceView(context)
    private val sessionManager = ArSessionManager(activity)
    private val backgroundRenderer = BackgroundRenderer()

    init {
        sessionManager.statusListener = object : ArSessionManager.StatusListener {
            override fun onStatus(status: String, message: String?) {
                events.emitStatus(status, message)
            }
        }
        sessionManager.poseListener = object : ArSessionManager.PoseListener {
            override fun onPose(tracking: Boolean, px: Float, pz: Float, fx: Float, fz: Float) {
                events.emitPose(tracking, px, pz, fx, fz)
            }
        }
        sessionManager.detectionListener = object : ArSessionManager.DetectionListener {
            override fun onDetections(
                imageWidth: Int,
                imageHeight: Int,
                barcodes: List<ArSessionManager.DetectedBarcode>,
            ) {
                events.emitDetections(imageWidth, imageHeight, barcodes)
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
        events.clearStatus()
        onDispose()
    }
}

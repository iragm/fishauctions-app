package com.fishauctions.app.ar

import android.opengl.GLES11Ext
import android.opengl.GLES20
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

// Renders ARCore's camera passthrough texture as a fullscreen quad. This is the standard
// ARCore-sample background renderer (see Google's `HelloAR` sample's BackgroundRenderer): a
// fullscreen triangle strip sampling an external OES texture (the format the camera driver
// writes into, and the only texture type `Session.setCameraTextureName` accepts), with UVs
// re-mapped each frame via `Frame.transformCoordinates2d` so ARCore can compensate for display
// rotation/aspect without the app doing that math.
class BackgroundRenderer {
    var textureId = -1
        private set

    private var program = 0
    private var positionAttrib = 0
    private var texCoordAttrib = 0
    private var textureUniform = 0

    private val quadCoords =
        floatArrayOf(-1f, -1f, +1f, -1f, -1f, +1f, +1f, +1f)
    private val quadCoordsBuffer = directFloatBuffer(quadCoords)

    // Default (identity-ish) UVs; overwritten every frame by transformCoordinates2d once the
    // display geometry is known, but must be non-empty before the first frame renders.
    private var quadTexCoords = floatArrayOf(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f)
    private var quadTexCoordsBuffer = directFloatBuffer(quadTexCoords)

    private fun directFloatBuffer(values: FloatArray): FloatBuffer =
        ByteBuffer.allocateDirect(values.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(values)
                position(0)
            }

    fun createOnGlThread() {
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        val target = GLES11Ext.GL_TEXTURE_EXTERNAL_OES
        GLES20.glBindTexture(target, textureId)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertexShader)
        GLES20.glAttachShader(program, fragmentShader)
        GLES20.glLinkProgram(program)
        GLES20.glUseProgram(program)
        positionAttrib = GLES20.glGetAttribLocation(program, "a_Position")
        texCoordAttrib = GLES20.glGetAttribLocation(program, "a_TexCoord")
        textureUniform = GLES20.glGetUniformLocation(program, "u_Texture")
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        return shader
    }

    /** Re-maps the fullscreen quad's UVs for the current display rotation/aspect. */
    fun updateTexCoords(frame: com.google.ar.core.Frame) {
        if (frame.hasDisplayGeometryChanged()) {
            val out = FloatArray(8)
            frame.transformCoordinates2d(
                com.google.ar.core.Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES,
                quadCoords,
                com.google.ar.core.Coordinates2d.TEXTURE_NORMALIZED,
                out,
            )
            quadTexCoords = out
            quadTexCoordsBuffer = directFloatBuffer(out)
        }
    }

    fun draw() {
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glDepthMask(false)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glUniform1i(textureUniform, 0)

        quadCoordsBuffer.position(0)
        GLES20.glVertexAttribPointer(positionAttrib, 2, GLES20.GL_FLOAT, false, 0, quadCoordsBuffer)
        quadTexCoordsBuffer.position(0)
        GLES20.glVertexAttribPointer(texCoordAttrib, 2, GLES20.GL_FLOAT, false, 0, quadTexCoordsBuffer)
        GLES20.glEnableVertexAttribArray(positionAttrib)
        GLES20.glEnableVertexAttribArray(texCoordAttrib)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(positionAttrib)
        GLES20.glDisableVertexAttribArray(texCoordAttrib)
        GLES20.glDepthMask(true)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
    }

    companion object {
        private const val VERTEX_SHADER = """
            attribute vec4 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() {
                gl_Position = a_Position;
                v_TexCoord = a_TexCoord;
            }
        """

        private const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 v_TexCoord;
            uniform samplerExternalOES u_Texture;
            void main() {
                gl_FragColor = texture2D(u_Texture, v_TexCoord);
            }
        """
    }
}

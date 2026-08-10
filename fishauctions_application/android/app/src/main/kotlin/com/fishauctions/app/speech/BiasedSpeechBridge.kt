package com.fishauctions.app.speech

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `android.speech.SpeechRecognizer`, driven directly, so that the auction's own lot and bidder
 * numbers can be handed to it as `EXTRA_BIASING_STRINGS`.
 *
 * That extra is the entire reason this file exists. `speech_to_text` — which is otherwise a
 * perfectly good wrapper and still the default backend — never sets it and has no extension point
 * that could: `SpeechListenOptions` has a fixed set of fields, and `initialize(options:)` is
 * per-process and reads exactly one name. Without biasing, a club whose bidder numbers are
 * initials ("NM", "BOB") is asking a general-purpose dictation model to produce strings it has
 * essentially no prior for.
 *
 * **Scope: one utterance.** Sessions, re-arming, silence windows, the on-device fallback and
 * promoting a last partial all live in Dart (`RestartingSpeechBackend`), because that logic is
 * identical on both platforms and has already been wrong three times. This side starts a
 * recognizer, forwards what it says, and stops. Keeping it that small is what makes two native
 * implementations reviewable.
 *
 * **Error codes are `speech_to_text`'s strings on purpose** — `error_no_match`,
 * `error_speech_timeout`, and so on. Dart classifies errors in exactly one place for both
 * backends, and inventing a second vocabulary here would mean the "these are really just a
 * speaker who stopped" rules had to be written twice.
 */
class BiasedSpeechBridge(
    private val context: Context,
    methodChannel: MethodChannel,
    eventChannel: EventChannel,
) {

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    /**
     * The recognizer for the utterance in flight, and the only one whose callbacks count.
     *
     * A fresh `SpeechRecognizer` per utterance is deliberate — reusing one is the documented way
     * to get `ERROR_RECOGNIZER_BUSY`, and in practice one that quietly stops delivering partials
     * after a few phrases. But a recognizer that has been asked to stop keeps calling back for a
     * moment afterwards, so an utterance that starts in that window would otherwise be torn down
     * by its predecessor's `onResults`. Every callback checks it is still the current one; see
     * [Utterance].
     */
    private var current: Utterance? = null

    init {
        methodChannel.setMethodCallHandler { call, result -> onMethodCall(call, result) }
        eventChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink) {
                    sink = events
                }

                override fun onCancel(args: Any?) {
                    sink = null
                }
            },
        )
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(isAvailable())
            "supportsBias" -> result.success(supportsBias())
            "start" -> {
                start(call)
                result.success(null)
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // Mirrors MainActivity.isSpeechRecognitionAvailable: package visibility (Android 11+) means
    // this only sees a service because AndroidManifest declares the <queries><intent> for
    // android.speech.RecognitionService.
    private fun isAvailable(): Boolean = try {
        val onDevice = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        SpeechRecognizer.isRecognitionAvailable(context) || onDevice
    } catch (e: Throwable) {
        false
    }

    /**
     * `EXTRA_BIASING_STRINGS` is API 33. `minSdk` here is 28, so a real share of phones get this
     * backend's recognizer without its point — which is fine (it still recognizes speech) as long
     * as nothing claims otherwise. Dart surfaces this to the settings panel rather than assuming.
     */
    private fun supportsBias(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU

    private fun start(call: MethodCall) {
        stop()
        val onDevice = call.argument<Boolean>("onDevice") == true
        val locale = call.argument<String>("localeId") ?: "en-US"
        val pauseMillis = call.argument<Int>("pauseMillis") ?: 3000
        val maxAlternates = call.argument<Int>("maxAlternates") ?: 5
        val bias = call.argument<List<String>>("biasPhrases").orEmpty()

        main.post {
            // Whatever was running is no longer current, so its callbacks stop counting from
            // here — see [Utterance].
            current?.release()
            current = null
            val utterance = Utterance()
            try {
                val speech = if (onDevice && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
                } else {
                    SpeechRecognizer.createSpeechRecognizer(context)
                }
                speech.setRecognitionListener(utterance)
                utterance.speech = speech
                current = utterance
                speech.startListening(intentFor(locale, onDevice, pauseMillis, maxAlternates, bias))
                emit(mapOf("type" to "status", "listening" to true))
            } catch (e: Throwable) {
                current = null
                utterance.release()
                emit(mapOf("type" to "error", "code" to "error_client"))
            }
        }
    }

    private fun intentFor(
        locale: String,
        onDevice: Boolean,
        pauseMillis: Int,
        maxAlternates: Int,
        bias: List<String>,
    ): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        // FREE_FORM, not WEB_SEARCH: the utterance is a sentence ("lot forty two bidder
        // seventeen twenty five dollars sold"), not a query, and web-search mode returns
        // fewer and shorter alternates.
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, maxAlternates)
        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        // Generous on purpose: Dart holds the real silence clock, because Android's endpointer
        // and iOS's (which has no such control at all) cannot be made to agree. This only needs
        // to be long enough that the platform doesn't cut in first.
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, pauseMillis)
        putExtra(
            RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
            pauseMillis,
        )
        if (onDevice) {
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }
        // The point of the whole file. Skipped when empty: on some builds an empty array is
        // treated as "bias towards nothing", which is not the same as not biasing.
        if (bias.isNotEmpty() && supportsBias()) {
            putExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(bias))
        }
    }

    private fun stop() {
        main.post { current?.stopListening() }
    }

    /**
     * One recognizer and its callbacks. Everything it reports is dropped unless it is still
     * [current], which is what keeps a stopped utterance from ending its successor.
     */
    private inner class Utterance : RecognitionListener {
        var speech: SpeechRecognizer? = null

        private val isCurrent: Boolean get() = current === this

        fun release() {
            val recognizer = speech ?: return
            speech = null
            try {
                recognizer.destroy()
            } catch (e: Throwable) {
                // Nothing useful to do; the next start creates a fresh one regardless.
            }
        }

        fun stopListening() {
            // stopListening, not destroy: this asks the recognizer to finish and deliver its
            // final result, which is the best transcript of the phrase. Destroying here throws
            // it away, which is exactly the bug Dart's _flushPendingAsFinal works around.
            try {
                speech?.stopListening()
            } catch (e: Throwable) {
                // Already gone.
            }
        }

        override fun onReadyForSpeech(params: Bundle?) = Unit

        override fun onBeginningOfSpeech() = Unit

        /**
         * Android's RMS is roughly -2..10 dB and iOS reports nothing at all, so both native sides
         * normalize to 0..1 here rather than leaving Dart to know which platform it is on. The
         * meter only ever answers "is it hearing me".
         */
        override fun onRmsChanged(rmsdB: Float) {
            if (!isCurrent) return
            val level = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f).toDouble()
            emit(mapOf("type" to "level", "level" to level))
        }

        override fun onBufferReceived(buffer: ByteArray?) = Unit

        override fun onEndOfSpeech() = Unit

        override fun onError(error: Int) {
            if (!isCurrent) {
                release()
                return
            }
            finish()
            emit(mapOf("type" to "error", "code" to codeFor(error)))
        }

        override fun onResults(results: Bundle?) {
            if (!isCurrent) {
                release()
                return
            }
            val payload = resultPayload(results, isFinal = true)
            finish()
            emit(payload)
            // The status is what drives Dart's end-of-utterance, and it has to follow the words:
            // the base class flushes anything pending when a phrase ends, so a status arriving
            // first would promote the last partial and leave the real final for the next one.
            emit(mapOf("type" to "status", "listening" to false))
        }

        override fun onPartialResults(partialResults: Bundle?) {
            if (!isCurrent) return
            emit(resultPayload(partialResults, isFinal = false))
        }

        override fun onEvent(eventType: Int, params: Bundle?) = Unit

        private fun finish() {
            current = null
            release()
        }
    }

    private fun resultPayload(results: Bundle?, isFinal: Boolean): Map<String, Any?> {
        val texts = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
        // Confidence is optional and frequently absent; -1 is the agreed "the platform didn't
        // say", which Dart's confidence model treats as neutral rather than as doubt — it
        // computes its own score from three other signals.
        val scores = results?.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
        return mapOf(
            "type" to "result",
            "final" to isFinal,
            "alternates" to texts.mapIndexed { index, text ->
                mapOf(
                    "text" to text,
                    "confidence" to (scores?.getOrNull(index)?.toDouble() ?: -1.0),
                )
            },
        )
    }

    // speech_to_text's own strings, deliberately: Dart classifies errors in one place for both
    // backends and both platforms, and a second vocabulary here would mean writing the "these
    // are really just a speaker who stopped" rules twice.
    private fun codeFor(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "error_audio_error"
        SpeechRecognizer.ERROR_CLIENT -> "error_client"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "error_permission"
        SpeechRecognizer.ERROR_NETWORK -> "error_network"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "error_network_timeout"
        SpeechRecognizer.ERROR_NO_MATCH -> "error_no_match"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "error_busy"
        SpeechRecognizer.ERROR_SERVER -> "error_server"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "error_speech_timeout"
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "error_language_not_supported"
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "error_language_unavailable"
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "error_server_disconnected"
        SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "error_too_many_requests"
        else -> "error_unknown"
    }

    private fun emit(payload: Map<String, Any?>) {
        main.post { sink?.success(payload) }
    }
}

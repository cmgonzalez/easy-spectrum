package cl.easysoft.easyspectrum

import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "cl.easysoft.easyspectrum/audio"
    private val OPEN_CHANNEL = "cl.easysoft.easyspectrum/open"
    private var openChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getNativeSampleRate" -> {
                    val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
                    val sampleRate = audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull()
                    result.success(sampleRate ?: 48000)
                }
                else -> result.notImplemented()
            }
        }

        // Vibración de los controles con duración e intensidad propias (lib/core/haptics.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cl.easysoft.easyspectrum/haptics")
            .setMethodCallHandler { call, result ->
                if (call.method == "vibrate") {
                    vibrate(call.argument<Int>("ms") ?: 15, call.argument<Int>("amplitude") ?: 120)
                    result.success(null)
                } else result.notImplemented()
            }

        // Archivos abiertos con "Abrir con" / "Compartir". Dart pide el del arranque
        // con "initial"; los que llegan con la app abierta se envían con "open".
        openChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OPEN_CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initial" -> {
                        val uri = takeUri(intent)
                        if (uri == null) result.success(null) else readAsync(uri) { result.success(it) }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private val vibrator: Vibrator? by lazy {
        if (Build.VERSION.SDK_INT >= 31)
            (getSystemService(VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        else @Suppress("DEPRECATION") (getSystemService(VIBRATOR_SERVICE) as? Vibrator)
    }

    private fun vibrate(ms: Int, amplitude: Int) {
        val v = vibrator ?: return
        if (!v.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= 26) {
            val amp = if (v.hasAmplitudeControl()) amplitude.coerceIn(1, 255) else VibrationEffect.DEFAULT_AMPLITUDE
            v.vibrate(VibrationEffect.createOneShot(ms.toLong(), amp))
        } else @Suppress("DEPRECATION") v.vibrate(ms.toLong())
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uri = takeUri(intent) ?: return
        readAsync(uri) { openChannel?.invokeMethod("open", it) }
    }

    /** URI del archivo recibido, una sola vez (se marca el intent como consumido). */
    private fun takeUri(intent: Intent?): Uri? {
        if (intent == null) return null
        val uri = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
            else -> null
        }
        if (uri != null) intent.action = Intent.ACTION_MAIN
        return uri
    }

    /** Lee nombre y bytes fuera del hilo principal (Drive puede tener que descargarlo). */
    private fun readAsync(uri: Uri, done: (Map<String, Any?>) -> Unit) {
        Thread {
            val map: Map<String, Any?> = try {
                val bytes = contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                mapOf("name" to displayName(uri), "bytes" to bytes)
            } catch (e: Exception) {
                mapOf("name" to displayName(uri), "bytes" to null)
            }
            runOnUiThread { done(map) }
        }.start()
    }

    private fun displayName(uri: Uri): String {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0)?.let { return it }
            }
        } catch (_: Exception) {}
        return uri.lastPathSegment?.substringAfterLast('/') ?: "game"
    }
}

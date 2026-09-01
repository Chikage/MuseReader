package com.musereader.muse_reader

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val FILE_CHANNEL = "com.musereader/files"
        private const val ENGINE_CHANNEL = "com.musereader/musescore_engine"
        private const val PICK_SCORE_REQUEST = 4101
    }

    private var pendingFileResult: MethodChannel.Result? = null
    private lateinit var fallbackSynth: SimpleScoreSynth
    private lateinit var fluidSynth: FluidScoreSynth
    private val engineExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        fallbackSynth = SimpleScoreSynth()
        fluidSynth = FluidScoreSynth()
        val engineAvailable = NativeMuseScoreEngine.isAvailable()
        val engineReady = engineAvailable && NativeMuseScoreEngine.initialize()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickScoreFile" -> pickScoreFile(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ENGINE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.success(
                                mapOf(
                                    "available" to engineAvailable,
                                    "error" to "The score path is empty.",
                                ),
                            )
                        } else if (!engineReady) {
                            result.success(
                                mapOf(
                                    "available" to engineAvailable,
                                    "error" to (
                                        NativeMuseScoreEngine.lastError()
                                            ?: "MuseScore native initialization failed."
                                    ),
                                ),
                            )
                        } else {
                            engineExecutor.execute {
                                val json = NativeMuseScoreEngine.open(path)
                                val response = if (json == null) {
                                    mapOf(
                                        "available" to engineAvailable,
                                        "error" to (
                                            NativeMuseScoreEngine.lastError()
                                                ?: "MuseScore native rendering failed."
                                        ),
                                    )
                                } else {
                                    try {
                                        mapOf(
                                            "available" to true,
                                            "document" to JSONObject(json).toPlatformValue(),
                                        )
                                    } catch (error: Exception) {
                                        mapOf(
                                            "available" to engineAvailable,
                                            "error" to (error.message ?: "Invalid native document"),
                                        )
                                    }
                                }
                                runOnUiThread { result.success(response) }
                            }
                        }
                    }
                    "startAudio" -> {
                        val events = call.argument<List<Any?>>("events") ?: emptyList()
                        val positionUs = (call.argument<Number>("positionUs") ?: 0).toLong()
                        val speed = (call.argument<Number>("speed") ?: 1.0).toDouble()
                        fallbackSynth.stop()
                        if (!fluidSynth.start(events, positionUs, speed)) {
                            fallbackSynth.start(events, positionUs, speed)
                        }
                        result.success(null)
                    }
                    "stopAudio" -> {
                        fluidSynth.stop()
                        fallbackSynth.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickScoreFile(result: MethodChannel.Result) {
        if (pendingFileResult != null) {
            result.error("picker_busy", "A file picker is already open.", null)
            return
        }
        pendingFileResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/octet-stream", "application/zip", "text/xml", "application/xml"),
            )
        }
        startActivityForResult(intent, PICK_SCORE_REQUEST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_SCORE_REQUEST) return
        val result = pendingFileResult
        pendingFileResult = null
        if (result == null) return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        try {
            result.success(copyToCache(data.data!!))
        } catch (error: Exception) {
            result.error("copy_failed", error.message, null)
        }
    }

    private fun copyToCache(uri: Uri): String {
        val name = displayName(uri)
        val safeName = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val directory = File(cacheDir, "muse_reader/imports").apply { mkdirs() }
        val target = File(directory, "${System.currentTimeMillis()}_$safeName")
        contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Cannot open the selected file." }
            target.outputStream().use { output -> input.copyTo(output) }
        }
        return target.absolutePath
    }

    private fun displayName(uri: Uri): String {
        var cursor: Cursor? = null
        try {
            cursor = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            if (cursor != null && cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) return cursor.getString(index)
            }
        } finally {
            cursor?.close()
        }
        return uri.lastPathSegment ?: "score.mscx"
    }

    override fun onDestroy() {
        if (::fluidSynth.isInitialized) fluidSynth.stop()
        if (::fallbackSynth.isInitialized) fallbackSynth.stop()
        engineExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun JSONObject.toPlatformValue(): Map<String, Any?> {
        val result = linkedMapOf<String, Any?>()
        val keys = keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = opt(key).toPlatformValue()
        }
        return result
    }

    private fun JSONArray.toPlatformValue(): List<Any?> =
        (0 until length()).map { opt(it).toPlatformValue() }

    private fun Any?.toPlatformValue(): Any? = when (this) {
        JSONObject.NULL -> null
        is JSONObject -> toPlatformValue()
        is JSONArray -> toPlatformValue()
        is Number -> this
        is Boolean -> this
        is String -> this
        else -> toString()
    }
}

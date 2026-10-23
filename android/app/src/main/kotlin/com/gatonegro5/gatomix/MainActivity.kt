package com.gatonegro5.gatomix

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.gatonegro5.gatomix/library",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "queryAudio" -> queryAudioAsync(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun queryAudioAsync(result: MethodChannel.Result) {
        Thread {
            try {
                deliver(result, queryAudio())
            } catch (e: SecurityException) {
                fail(result, "denied", e.message)
            } catch (e: Exception) {
                fail(result, "query", e.message)
            }
        }.start()
    }

    private fun deliver(result: MethodChannel.Result, value: List<Map<String, Any>>) {
        Handler(Looper.getMainLooper()).post {
            try {
                result.success(value)
            } catch (_: IllegalStateException) {
            }
        }
    }

    private fun fail(result: MethodChannel.Result, code: String, message: String?) {
        Handler(Looper.getMainLooper()).post {
            try {
                result.error(code, message, null)
            } catch (_: IllegalStateException) {
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun queryAudio(): List<Map<String, Any>> {
        val resolver = applicationContext.contentResolver
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }
        val projection = mutableListOf(
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.DATE_MODIFIED,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.DISPLAY_NAME,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            projection.add(MediaStore.Audio.Media.RELATIVE_PATH)
            projection.add(MediaStore.Audio.Media.VOLUME_NAME)
        }
        val rows = mutableListOf<Map<String, Any>>()
        resolver.query(
            collection,
            projection.toTypedArray(),
            "${MediaStore.Audio.Media.IS_MUSIC} != 0",
            null,
            null,
        )?.use { cursor ->
            val dataIdx = cursor.getColumnIndex(MediaStore.Audio.Media.DATA)
            val modifiedIdx = cursor.getColumnIndex(MediaStore.Audio.Media.DATE_MODIFIED)
            val sizeIdx = cursor.getColumnIndex(MediaStore.Audio.Media.SIZE)
            val nameIdx = cursor.getColumnIndex(MediaStore.Audio.Media.DISPLAY_NAME)
            val relativeIdx = cursor.getColumnIndex(MediaStore.Audio.Media.RELATIVE_PATH)
            val volumeIdx = cursor.getColumnIndex(MediaStore.Audio.Media.VOLUME_NAME)
            while (cursor.moveToNext()) {
                val data = if (dataIdx >= 0) cursor.getString(dataIdx) else null
                val relative = if (relativeIdx >= 0) cursor.getString(relativeIdx) else null
                val name = if (nameIdx >= 0) cursor.getString(nameIdx) else null
                val volume = if (volumeIdx >= 0) cursor.getString(volumeIdx) else null
                val path = filePath(data, relative, name, volume) ?: continue
                val rawModified = if (modifiedIdx >= 0) cursor.getLong(modifiedIdx) else 0L
                val modifiedMs = if (rawModified > 100_000_000_000L) rawModified else rawModified * 1000L
                val size = if (sizeIdx >= 0) cursor.getLong(sizeIdx) else 0L
                rows.add(
                    mapOf(
                        "path" to path,
                        "modifiedMs" to modifiedMs,
                        "size" to size,
                    ),
                )
            }
        }
        return rows
    }

    private fun filePath(
        data: String?,
        relative: String?,
        name: String?,
        volume: String?,
    ): String? {
        if (!data.isNullOrEmpty()) return data
        if (relative.isNullOrEmpty() || name.isNullOrEmpty()) return null
        val root = when (volume) {
            null, "", MediaStore.VOLUME_EXTERNAL_PRIMARY -> "/storage/emulated/0"
            else -> "/storage/$volume"
        }
        val rel = if (relative.endsWith("/")) relative else "$relative/"
        return "$root/$rel$name"
    }
}

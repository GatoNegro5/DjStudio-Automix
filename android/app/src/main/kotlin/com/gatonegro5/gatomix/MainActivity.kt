package com.gatonegro5.gatomix

import android.content.Context
import android.os.Build
import android.os.PowerManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gatomix/thermal")
            .setMethodCallHandler { call, result ->
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                when (call.method) {
                    "status" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                            result.success(null)
                        } else {
                            result.success(pm.currentThermalStatus)
                        }
                    }
                    "headroom" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        val h = pm.getThermalHeadroom(10)
                        if (h.isNaN()) result.success(null) else result.success(h.toDouble())
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
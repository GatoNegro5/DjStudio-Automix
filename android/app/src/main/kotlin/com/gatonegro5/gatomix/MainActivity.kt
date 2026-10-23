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
                if (call.method != "status") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(pm.currentThermalStatus)
            }
    }
}
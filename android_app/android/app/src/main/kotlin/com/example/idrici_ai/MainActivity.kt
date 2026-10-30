package com.example.idrici_ai

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val VISION_CHANNEL = "com.idrici.ai/vision"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VISION_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getNativeBridgeStatus" -> {
                    result.success(
                        mapOf(
                            "platform" to "android",
                            "bridge" to "ready"
                        )
                    )
                }
                else -> result.notImplemented()
            }
        }
    }
}

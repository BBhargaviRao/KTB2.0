package com.example.ktb_nudges

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "ktb_nudges/adm"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAdmRegistrationId" -> {
                        val prefs = getSharedPreferences("ktb_adm_prefs", Context.MODE_PRIVATE)
                        val token = prefs.getString("adm_registration_id", null)
                        result.success(token)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
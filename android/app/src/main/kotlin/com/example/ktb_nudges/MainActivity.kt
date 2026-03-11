package com.example.ktb_nudges

import android.content.Context
import android.os.Bundle
import android.util.Log
import com.amazon.device.messaging.ADM
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    private val CHANNEL = "ktb_nudges/adm"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.e("KTB_ADM", "MainActivity onCreate started")

        thread {
            try {
                val adm = ADM(this)
                val registrationId = adm.registrationId

                if (registrationId == null) {
                    Log.e("KTB_ADM", "No ADM registration ID yet. Starting registration.")
                    adm.startRegister()
                } else {
                    Log.e("KTB_ADM", "Existing ADM registration ID: $registrationId")
                }
            } catch (e: Exception) {
                Log.e("KTB_ADM", "ADM setup failed: ${e.message}", e)
            }
        }
    }

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
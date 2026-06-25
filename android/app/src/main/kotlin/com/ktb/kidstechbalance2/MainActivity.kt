package com.ktb.kidstechbalance2

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import com.amazon.device.messaging.ADM
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    private val CHANNEL = "ktb2/adm"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.e("KTB_ADM", "MainActivity onCreate started")

        val isAmazonDevice =
            Build.MANUFACTURER.equals("Amazon", ignoreCase = true) ||
            Build.BRAND.equals("Amazon", ignoreCase = true)

        if (!isAmazonDevice) {
            Log.e("KTB_ADM", "Non-Amazon device detected. Skipping ADM setup.")
            return
        }

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
            } catch (t: Throwable) {
                Log.e("KTB_ADM", "ADM setup failed: ${t.message}", t)
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ktb2/usage_stats")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(UsageStatsHelper.hasPermission(this))
                    "requestPermission" -> {
                        startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                        result.success(null)
                    }
                    "getDailyUsage" -> {
                        if (!UsageStatsHelper.hasPermission(this)) {
                            result.error("NO_PERMISSION", "Usage Access not granted", null)
                            return@setMethodCallHandler
                        }
                        val dateMillis = call.argument<Long>("dateMillis")
                            ?: System.currentTimeMillis()
                        thread {
                            try {
                                val data = UsageStatsHelper.getDailyUsage(this, dateMillis)
                                runOnUiThread { result.success(data) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("ERROR", e.message, null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
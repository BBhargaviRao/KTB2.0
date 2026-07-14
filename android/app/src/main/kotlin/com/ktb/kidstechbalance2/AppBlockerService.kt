package com.ktb.kidstechbalance2

import android.app.*
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.os.*
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.*
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import org.json.JSONObject
import kotlin.concurrent.thread

class AppBlockerService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private var allowedPackages: Set<String> = emptySet()
    // The session's own selected apps only (no KTB/launcher/systemui exemptions)
    // — this is what actually counts as "screen time used" for the session.
    private var sessionApps: Set<String> = emptySet()
    private var familyId: String = ""
    private var overlayView: View? = null
    private var windowManager: WindowManager? = null
    private var lastForeground: String? = null
    private var usedSeconds: Int = 0
    private var lastUploadedMinutes: Int = -1
    private var sessionId: String = ""

    // Fire OS's "Game Mode" kills this process outright (ActivityManager log:
    // "Killing ... GameMode killAllBackgroundProcesses") the moment a game
    // gains foreground, wiping all in-memory state including usedSeconds —
    // not something app code can prevent. Persisting progress here, keyed by
    // sessionId, lets onStartCommand recognize a redelivered intent for the
    // SAME session (see START_REDELIVER_INTENT below) and resume the count
    // instead of silently restarting from 0 every time the OS kills us.
    private val prefs by lazy { getSharedPreferences("ktb_blocker_prefs", Context.MODE_PRIVATE) }

    // Home-screen launcher(s) and system UI must never be blocked — otherwise the
    // overlay covers the launcher itself as soon as the session starts.
    private val systemPackages: Set<String> by lazy {
        val homeIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val launchers = packageManager.queryIntentActivities(homeIntent, PackageManager.MATCH_DEFAULT_ONLY)
            .map { it.activityInfo.packageName }
            .toSet()
        launchers + "com.android.systemui"
    }

    private val pollRunnable = object : Runnable {
        override fun run() {
            pollForeground()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val extra = intent?.getStringArrayListExtra("allowedPackages") ?: arrayListOf()
        sessionApps = extra.toSet()
        familyId = intent?.getStringExtra("familyId") ?: ""
        sessionId = intent?.getStringExtra("sessionId") ?: ""
        // Always allow KTB itself, the home launcher, and system UI
        allowedPackages = sessionApps + packageName + systemPackages

        // START_REDELIVER_INTENT means Android redelivers this SAME intent
        // (same extras) after the OS kills this process, instead of an empty
        // one — but the process restart still wipes usedSeconds/lastUploaded
        // Minutes from memory. Resume from persisted progress when this is
        // the same session picking back up; only reset to 0 for a genuinely
        // new session.
        if (sessionId.isNotEmpty() && prefs.getString("sessionId", null) == sessionId) {
            usedSeconds = prefs.getInt("usedSeconds", 0)
            lastUploadedMinutes = prefs.getInt("lastUploadedMinutes", -1)
            Log.d(TAG, "Service restarted (Fire OS kill recovery) — resuming at ${usedSeconds}s for session $sessionId")
        } else {
            usedSeconds = 0
            lastUploadedMinutes = -1
            prefs.edit()
                .putString("sessionId", sessionId)
                .putInt("usedSeconds", 0)
                .putInt("lastUploadedMinutes", -1)
                .apply()
            Log.d(TAG, "Service started. Allowed: $allowedPackages, familyId: $familyId, session: $sessionId")
        }

        startForeground(NOTIF_ID, buildNotification())
        handler.post(pollRunnable)
        return START_REDELIVER_INTENT
    }

    private fun pollForeground() {
        val usm = getSystemService(USAGE_STATS_SERVICE) as UsageStatsManager
        val end = System.currentTimeMillis()
        // If we've never seen a foreground-switch event yet, look back much
        // further (24h) to pick up an app the child was already sitting in
        // before this service started — otherwise lastForeground stays null
        // forever until they happen to switch apps again, and nothing is ever
        // counted or uploaded even though they're actively using an allowed app.
        val lookbackMs = if (lastForeground == null) 24L * 60 * 60 * 1000 else 10_000L
        val events = usm.queryEvents(end - lookbackMs, end)
        val ev = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(ev)
            if (ev.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND ||
                ev.eventType == UsageEvents.Event.ACTIVITY_RESUMED) {
                lastForeground = ev.packageName
            }
        }
        val current = lastForeground ?: return
        val blocked = !allowedPackages.contains(current)
        if (blocked && overlayView == null) showOverlay()
        else if (!blocked && overlayView != null) removeOverlay()

        // Count time spent in the session's own selected apps (not KTB/launcher/
        // systemui) and upload to Firestore every minute — runs in this native
        // foreground service, so it keeps working even if the child fully closes
        // the Flutter app, unlike the old Dart-side polling timer.
        if (sessionApps.contains(current)) {
            usedSeconds += 1
            prefs.edit().putInt("usedSeconds", usedSeconds).apply()
            val minutes = usedSeconds / 60
            if (minutes > lastUploadedMinutes) {
                lastUploadedMinutes = minutes
                prefs.edit().putInt("lastUploadedMinutes", lastUploadedMinutes).apply()
                uploadUsageToFirestore(minutes)
            }
        }
    }

    private fun uploadUsageToFirestore(minutes: Int) {
        if (familyId.isEmpty()) return
        val dateKey = todayKey()
        thread {
            try {
                val urlStr = "https://firestore.googleapis.com/v1/projects/$PROJECT_ID" +
                    "/databases/(default)/documents/families/$familyId" +
                    "/dashboard_days/$dateKey" +
                    "?key=$FIRESTORE_API_KEY" +
                    "&updateMask.fieldPaths=screenTimeUsedMinutes" +
                    "&updateMask.fieldPaths=screenTimeLastUpdatedAt"
                val conn = URL(urlStr).openConnection() as HttpURLConnection
                conn.requestMethod = "PATCH"
                conn.setRequestProperty("Content-Type", "application/json")
                conn.doOutput = true
                conn.connectTimeout = 10_000
                conn.readTimeout = 10_000

                val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
                    timeZone = TimeZone.getTimeZone("UTC")
                }.format(Date())

                val body = JSONObject().apply {
                    put("fields", JSONObject().apply {
                        put("screenTimeUsedMinutes", JSONObject().put("integerValue", minutes.toString()))
                        put("screenTimeLastUpdatedAt", JSONObject().put("timestampValue", iso))
                    })
                }
                conn.outputStream.use { it.write(body.toString().toByteArray()) }
                val code = conn.responseCode
                Log.d(TAG, "Uploaded $minutes min for $dateKey, response: $code")
                conn.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "Failed to upload usage minutes: ${e.message}")
            }
        }
    }

    private fun todayKey(): String {
        val f = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        return f.format(Date())
    }

    private fun showOverlay() {
        if (!Settings.canDrawOverlays(this)) {
            Log.w(TAG, "No overlay permission — skipping overlay")
            return
        }
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(80, 80, 80, 80)
            setBackgroundColor(Color.parseColor("#F5F3FF"))
        }

        TextView(this).apply {
            text = "🔒"  // 🔒
            textSize = 52f
            gravity = Gravity.CENTER
            root.addView(this)
        }

        TextView(this).apply {
            text = "App not available"
            textSize = 22f
            setTextColor(Color.parseColor("#2D2B55"))
            gravity = Gravity.CENTER
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, 32, 0, 0)
            root.addView(this)
        }

        TextView(this).apply {
            text = "This app isn’t part of your session.\nFocus on your allowed apps!"
            textSize = 15f
            setTextColor(Color.parseColor("#6E6A8E"))
            gravity = Gravity.CENTER
            setPadding(0, 20, 0, 56)
            root.addView(this)
        }

        Button(this).apply {
            text = "Go to Home Screen"
            setBackgroundColor(Color.parseColor("#7C6FCD"))
            setTextColor(Color.WHITE)
            textSize = 16f
            setPadding(80, 32, 80, 32)
            setOnClickListener {
                // Launch the device's home launcher — it's in systemPackages so the
                // overlay is removed as soon as it comes to the foreground.
                val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                    addCategory(Intent.CATEGORY_HOME)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(homeIntent)
            }
            root.addView(this)
        }

        val overlayType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_SYSTEM_ALERT

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayType,
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        )

        overlayView = root
        windowManager?.addView(root, params)
        Log.d(TAG, "Overlay shown")
    }

    private fun removeOverlay() {
        try { overlayView?.let { windowManager?.removeView(it) } } catch (_: Exception) {}
        overlayView = null
        Log.d(TAG, "Overlay removed")
    }

    private fun buildNotification(): Notification {
        val channelId = "ktb_session_blocker"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                channelId, "KTB Session", NotificationManager.IMPORTANCE_LOW
            )
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(ch)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, channelId)
        else
            @Suppress("DEPRECATION") Notification.Builder(this)
        return builder
            .setContentTitle("KTB Session Active")
            .setContentText("Screen time monitoring is running")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .build()
    }

    override fun onDestroy() {
        handler.removeCallbacks(pollRunnable)
        removeOverlay()
        // Final upload so the last partial minute isn't lost when the session ends.
        val minutes = usedSeconds / 60
        if (minutes > lastUploadedMinutes) uploadUsageToFirestore(minutes)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "KtbBlocker"
        const val NOTIF_ID = 7742
        // Same Firestore REST endpoint/key as the iOS KtbActivityMonitor extension
        // (ios/KtbActivityMonitor/KtbActivityMonitor.swift) — keeps both platforms
        // writing to the exact same families/{familyId}/dashboard_days/{dateKey}
        // document the parent's dashboard already reads.
        private const val PROJECT_ID = "ktb2-kidstechbalance"
        private const val FIRESTORE_API_KEY = "AIzaSyBwmXPgchb0wWni_ViA-qCWONg-pVSyZP0"
    }
}

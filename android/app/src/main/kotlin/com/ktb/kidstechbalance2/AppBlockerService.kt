package com.ktb.kidstechbalance2

import android.app.*
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
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

class AppBlockerService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private var allowedPackages: Set<String> = emptySet()
    private var overlayView: View? = null
    private var windowManager: WindowManager? = null
    private var lastForeground: String? = null

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
        // Always allow KTB itself, the home launcher, and system UI
        allowedPackages = extra.toSet() + packageName + systemPackages
        Log.d(TAG, "Service started. Allowed: $allowedPackages")
        startForeground(NOTIF_ID, buildNotification())
        handler.post(pollRunnable)
        return START_STICKY
    }

    private fun pollForeground() {
        val usm = getSystemService(USAGE_STATS_SERVICE) as UsageStatsManager
        val end = System.currentTimeMillis()
        val events = usm.queryEvents(end - 10_000, end)
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
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "KtbBlocker"
        const val NOTIF_ID = 7742
    }
}

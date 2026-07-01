package com.ktb.kidstechbalance2

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import java.util.Calendar

object UsageStatsHelper {

    fun hasPermission(context: Context): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                context.applicationInfo.uid,
                context.packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                context.applicationInfo.uid,
                context.packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun getInstalledApps(context: Context): List<Map<String, String>> {
        val pm = context.packageManager
        val intent = android.content.Intent(android.content.Intent.ACTION_MAIN, null)
        intent.addCategory(android.content.Intent.CATEGORY_LAUNCHER)
        val activities = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0L))
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(intent, 0)
        }
        return activities.mapNotNull { ri ->
            try {
                val pkg = ri.activityInfo.packageName
                if (pkg == context.packageName) return@mapNotNull null
                val appName = ri.loadLabel(pm).toString()
                val appInfo = pm.getApplicationInfo(pkg, 0)
                mapOf(
                    "packageName"   to pkg,
                    "appName"       to appName,
                    "categoryLabel" to categoryLabel(appCategory(appInfo))
                )
            } catch (_: Exception) { null }
        }.sortedBy { it["appName"] }
    }

    fun getDailyUsage(context: Context, dateMillis: Long): List<Map<String, Any>> {
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val pm = context.packageManager

        val cal = Calendar.getInstance().apply {
            timeInMillis = dateMillis
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val startTime = cal.timeInMillis
        cal.add(Calendar.DAY_OF_MONTH, 1)
        val endTime = minOf(cal.timeInMillis, System.currentTimeMillis())

        // queryEvents gives exact-timestamp foreground/background events — the only
        // reliable way to get per-day usage without Samsung's INTERVAL_DAILY bucket
        // boundaries bleeding yesterday's time into today's totals.
        val events = usm.queryEvents(startTime, endTime) ?: return emptyList()
        val event = UsageEvents.Event()
        val foregroundMs = mutableMapOf<String, Long>()
        val sessionStart = mutableMapOf<String, Long>()

        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            val pkg = event.packageName
            when (event.eventType) {
                UsageEvents.Event.MOVE_TO_FOREGROUND -> {
                    sessionStart[pkg] = event.timeStamp
                }
                UsageEvents.Event.MOVE_TO_BACKGROUND -> {
                    val start = sessionStart.remove(pkg) ?: continue
                    foregroundMs[pkg] = (foregroundMs[pkg] ?: 0L) + (event.timeStamp - start)
                }
            }
        }
        // Apps still in foreground at endTime (no MOVE_TO_BACKGROUND seen yet)
        val now = minOf(endTime, System.currentTimeMillis())
        for ((pkg, start) in sessionStart) {
            foregroundMs[pkg] = (foregroundMs[pkg] ?: 0L) + (now - start)
        }

        return foregroundMs.entries
            .filter { it.value >= 60_000L }
            .sortedByDescending { it.value }
            .take(15)
            .mapNotNull { (pkg, ms) ->
                try {
                    val appInfo = pm.getApplicationInfo(pkg, 0)
                    val appName = pm.getApplicationLabel(appInfo).toString()
                    if (appName == pkg) return@mapNotNull null
                    val category = appCategory(appInfo)
                    mapOf(
                        "packageName" to pkg,
                        "appName" to appName,
                        "categoryLabel" to categoryLabel(category),
                        "timeMinutes" to (ms / 60_000L).toInt()
                    )
                } catch (_: PackageManager.NameNotFoundException) {
                    null
                }
            }
    }

    private fun appCategory(info: ApplicationInfo): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) info.category
        else ApplicationInfo.CATEGORY_UNDEFINED

    private fun categoryLabel(category: Int): String = when (category) {
        ApplicationInfo.CATEGORY_GAME        -> "Games"
        ApplicationInfo.CATEGORY_AUDIO       -> "Music & Audio"
        ApplicationInfo.CATEGORY_VIDEO       -> "Video"
        ApplicationInfo.CATEGORY_IMAGE       -> "Photography"
        ApplicationInfo.CATEGORY_SOCIAL      -> "Social"
        ApplicationInfo.CATEGORY_NEWS        -> "News"
        ApplicationInfo.CATEGORY_MAPS        -> "Maps"
        ApplicationInfo.CATEGORY_PRODUCTIVITY -> "Productivity"
        ApplicationInfo.CATEGORY_ACCESSIBILITY -> "Accessibility"
        else                                 -> "Other"
    }
}

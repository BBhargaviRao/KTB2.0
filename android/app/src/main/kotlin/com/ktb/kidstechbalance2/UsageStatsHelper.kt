package com.ktb.kidstechbalance2

import android.app.AppOpsManager
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

        val stats = usm.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, startTime, endTime)
            ?: return emptyList()

        return stats
            .filter { it.totalTimeInForeground >= 60_000L }
            .sortedByDescending { it.totalTimeInForeground }
            .take(15)
            .mapNotNull { stat ->
                try {
                    val appInfo = pm.getApplicationInfo(stat.packageName, 0)
                    // Skip system apps with no label
                    val appName = pm.getApplicationLabel(appInfo).toString()
                    if (appName == stat.packageName) return@mapNotNull null
                    val category = appCategory(appInfo)
                    mapOf(
                        "packageName" to stat.packageName,
                        "appName" to appName,
                        "categoryLabel" to categoryLabel(category),
                        "timeMinutes" to (stat.totalTimeInForeground / 60_000L).toInt()
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
